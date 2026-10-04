"""在 val 上评测**导出的 TFLite 模型**，算逐类 P / R。

## 为什么需要它

到目前为止**所有模型对比都是用 PyTorch 权重做的**（`compare_at_threshold.py`
用的是 `best.pt`），但**部署到手机上的是 int8 TFLite**。
量化会掉精度，而掉多少从来没测过 —— 于是「stage2 比 poc3 好」这个结论
可能在实际部署的那份产物上不成立。

`check_tflite_decode.py` 不能回答这个问题：它报告的是
「所有检出 × 所有 GT 取最大 IoU」的**平均最佳 IoU**，
那是**布局与坐标换算的体检**，不是检出质量（一个模型只检出一个框也能拿到高分）。

## 做法

按 Kotlin 的实现（`decode` / `nms` 都是从 `check_tflite_decode.py` 复用的、
已经和原生代码核对过的版本）跑完整链路：
letterbox -> invoke -> decode -> NMS -> 与 GT 按类配对（IoU ≥ 0.5）-> 累计 TP/FP/FN。

**与 ultralytics 口径的一个有意差异**：ultralytics 只对 GT 里出现过的类算 AP，
预测到其它类的框**直接被丢掉、不计入任何指标**。本脚本**额外报出**
「检出了 val 里不存在的类」的次数 —— 那正是 mAP 看不见的误报
（20 类模型在香港街景上乱报新类，mAP 上是零痕迹）。

用法：
    python scripts/eval_tflite_on_val.py --tflite <模型> --dataset data/dataset_poc5
    python scripts/eval_tflite_on_val.py --tflite A.tflite B.tflite --dataset ... --thresholds 0.30,0.70
"""
from __future__ import annotations

import argparse
import collections
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
# 复用已经与 Kotlin 逐行核对过的实现，避免两套解码逻辑各自漂移
from check_tflite_decode import decode, layout_of, letterbox, nms  # noqa: E402


def read_gt(label_path: Path) -> list[tuple[int, tuple[float, float, float, float]]]:
    """返回 [(类别本地索引, (x1,y1,x2,y2))]，坐标已归一化。"""
    out = []
    if not label_path.exists():
        return out
    for line in label_path.read_text(encoding="utf-8", errors="replace").splitlines():
        p = line.split()
        if len(p) < 5:
            continue
        try:
            cid = int(float(p[0]))
            cx, cy, w, h = (float(v) for v in p[1:5])
        except ValueError:
            continue
        out.append((cid, (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)))
    return out


def iou_xyxy(a: tuple[float, float, float, float],
             b: tuple[float, float, float, float]) -> float:
    iw = min(a[2], b[2]) - max(a[0], b[0])
    ih = min(a[3], b[3]) - max(a[1], b[1])
    if iw <= 0 or ih <= 0:
        return 0.0
    inter = iw * ih
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0.0


def as_xyxy(d: dict) -> tuple[float, float, float, float]:
    return (d["cx"] - d["w"] / 2, d["cy"] - d["h"] / 2,
            d["cx"] + d["w"] / 2, d["cy"] + d["h"] / 2)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tflite", nargs="+", required=True)
    ap.add_argument("--dataset", default="data/dataset_poc5")
    ap.add_argument("--split", default="val")
    ap.add_argument("--imgsz", type=int, default=416)
    ap.add_argument("--thresholds", default="0.30,0.50,0.70")
    ap.add_argument("--iou-match", type=float, default=0.5)
    args = ap.parse_args()

    ds = Path(args.dataset)
    if not ds.is_absolute():
        ds = REPO_ROOT / ds
    img_dir = ds / "images" / args.split
    lbl_dir = ds / "labels" / args.split
    imgs = sorted(p for p in img_dir.glob("*")
                  if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
    if not imgs:
        print(f"没找到图片：{img_dir}")
        return 1

    thresholds = [float(t) for t in args.thresholds.split(",") if t.strip()]
    # 预读 GT（每张图只读一次）
    gts = {p.stem: read_gt(lbl_dir / f"{p.stem}.txt") for p in imgs}
    gt_classes = collections.Counter()
    for v in gts.values():
        for cid, _ in v:
            gt_classes[cid] += 1
    print(f"val：{len(imgs)} 张图，GT 类别 {dict(sorted(gt_classes.items()))}")

    import tensorflow as tf

    for w in args.tflite:
        p = Path(w)
        if not p.exists():
            print(f"跳过（不存在）：{p}")
            continue
        run = p.parent.parent.name if p.parent.name == "best_saved_model" else p.stem
        it = tf.lite.Interpreter(model_path=str(p))
        it.allocate_tensors()
        ind, outd = it.get_input_details()[0], it.get_output_details()[0]
        anchor_major, channels, anchors, n_classes = layout_of(list(outd["shape"]))
        print(f"\n{'=' * 72}\n{run}  ({p.name})\n"
              f"  形状 {list(outd['shape'])} -> {'锚点优先' if anchor_major else '通道优先'}"
              f"  通道 {channels}  锚点 {anchors}  类别 {n_classes}")

        for thr in thresholds:
            tp: collections.Counter = collections.Counter()
            fp: collections.Counter = collections.Counter()
            fn: collections.Counter = collections.Counter()
            off_taxonomy = collections.Counter()
            for img_path in imgs:
                im = np.asarray(Image.open(img_path).convert("RGB"),
                                dtype=np.float32) / 255.0
                ten, nw, nh, px, py = letterbox(im, args.imgsz)
                it.set_tensor(ind["index"], ten)
                it.invoke()
                dets = nms(decode(it.get_tensor(outd["index"]), input_size=args.imgsz,
                                  new_w=nw, new_h=nh, pad_x=px, pad_y=py,
                                  threshold=thr, anchor_major=anchor_major))
                g = gts[img_path.stem]
                used = [False] * len(g)
                for d in dets:
                    cid = d["id"]
                    if cid not in gt_classes:
                        off_taxonomy[cid] += 1        # val 里没有这个类 -> 纯误报
                        continue
                    best_j, best_i = -1, 0.0
                    box = as_xyxy(d)
                    for j, (gc, gb) in enumerate(g):
                        if used[j] or gc != cid:
                            continue
                        v = iou_xyxy(box, gb)
                        if v > best_i:
                            best_i, best_j = v, j
                    if best_j >= 0 and best_i >= args.iou_match:
                        used[best_j] = True
                        tp[cid] += 1
                    else:
                        fp[cid] += 1
                for j, (gc, _) in enumerate(g):
                    if not used[j]:
                        fn[gc] += 1

            print(f"\n  --- conf >= {thr:.2f} ---")
            print(f"    {'本地索引':<10}{'GT':>5}{'TP':>5}{'FP':>5}{'FN':>5}"
                  f"{'P':>8}{'R':>8}")
            for cid in sorted(gt_classes):
                n = gt_classes[cid]
                t, f, m = tp[cid], fp[cid], fn[cid]
                prec = t / (t + f) if (t + f) else 0.0
                rec = t / n if n else 0.0
                print(f"    {cid:<10}{n:>5}{t:>5}{f:>5}{m:>5}{prec:>8.3f}{rec:>8.3f}")
            t_all = sum(tp.values())
            f_all = sum(fp.values())
            m_all = sum(fn.values())
            P = t_all / (t_all + f_all) if (t_all + f_all) else 0.0
            R = t_all / (t_all + m_all) if (t_all + m_all) else 0.0
            print(f"    {'合计':<10}{sum(gt_classes.values()):>5}{t_all:>5}"
                  f"{f_all:>5}{m_all:>5}{P:>8.3f}{R:>8.3f}")
            if off_taxonomy:
                tot = sum(off_taxonomy.values())
                print(f"    ⚠ 检出 val 里不存在的类 {tot} 次 "
                      f"（按本地索引：{dict(sorted(off_taxonomy.items()))}）")
                print(f"      —— 这些框在 ultralytics 的 mAP 里**完全不计入**，"
                      f"但真机上会画出来/播报出来")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
