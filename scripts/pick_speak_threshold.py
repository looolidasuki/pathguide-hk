"""用带人工标注的数据算「播报门槛」的精度/召回曲线。

## 为什么要单独定一个播报门槛

本项目有两个不同的阈值，作用完全不同，**不能共用**：

- **显示门槛**（界面上那根滑条，默认 0.30）：只影响屏幕上画不画框。
  画多一个框对用户的代价接近零——信息多一点总没坏处。
- **播报门槛**（本脚本要定的这个）：影响**说出口**的结果。
  代价不对称：漏报只是少一条信息，**误报会让视障用户对空无一物做出动作**，
  这在过马路、下楼梯这类场景里是危险，而不只是烦人。

所以播报必须比显示更严。问题只剩「严到多少」——这个值不该靠感觉定，
而应该看「在多少分以上时，检出的东西基本都是真的」。

## 判据

对每张图跑完整链路（letterbox -> 模型 -> 解码 -> NMS），把检出按分数从高到低
与人工标注按 IoU>=0.5 贪心配对。然后对每个候选门槛 t：

    precision(t) = 「分数 >= t 的检出」里真正命中标注的比例
    recall(t)    = 被「分数 >= t 的检出」命中的标注占全部标注的比例

门槛越高 precision 越高、recall 越低。取「precision 仍达标（默认 0.90）
的前提下最低的门槛」，这样既压掉误报，又不至于听不到真东西。

## 用法

    .venv-export/Scripts/python.exe scripts/pick_speak_threshold.py
    .venv-export/Scripts/python.exe scripts/pick_speak_threshold.py --target-precision 0.95
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_tflite_decode import (  # noqa: E402
    IMG_DIR, LBL_DIR, decode, iou, letterbox, nms, yolo_boxes,
)

REPO = Path(__file__).resolve().parents[1]
DEFAULT_TFLITE = REPO / "app" / "assets" / "models" / "detector.tflite"


def match_by_score(dets: list[dict], gts: list[tuple], iou_thr: float) -> list[bool]:
    """把检出按分数降序与标注贪心配对，返回与「按分数降序的检出」等长的命中标记。

    贪心+每个标注只能用一次，与评测时的常规做法一致。
    """
    used = [False] * len(gts)
    flags: list[bool] = []
    for d in sorted(dets, key=lambda d: -d["score"]):
        best_iou, best_i = iou_thr, -1
        for i, g in enumerate(gts):
            if used[i]:
                continue
            v = iou(d, g)
            if v >= best_iou:
                best_iou, best_i = v, i
        if best_i >= 0:
            used[best_i] = True
            flags.append(True)
        else:
            flags.append(False)
    return flags


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tflite", default=str(DEFAULT_TFLITE))
    ap.add_argument("--low", type=float, default=0.05,
                    help="统计下限：低于它的检出直接不采集（默认 0.05）")
    ap.add_argument("--iou", type=float, default=0.5, help="配对用的 IoU 门槛")
    ap.add_argument("--target-precision", type=float, default=0.90,
                    help="可接受的精度下限，用来反推推荐门槛")
    args = ap.parse_args()

    from ai_edge_litert.interpreter import Interpreter
    from PIL import Image

    it = Interpreter(model_path=args.tflite)
    it.allocate_tensors()
    ind = it.get_input_details()[0]
    outd = it.get_output_details()[0]
    in_shape = [int(v) for v in ind["shape"]]
    out_shape = [int(v) for v in outd["shape"]]
    input_size = in_shape[1]
    anchor_major = out_shape[1] > out_shape[2]

    images = sorted(IMG_DIR.glob("*.jpg"))
    if not images:
        print(f"没有图片：{IMG_DIR}")
        return 1

    # 每张图采集「所有 >= low 的检出」的分数与命中标记
    per_image: list[tuple[list[float], list[bool], int]] = []
    for p in images:
        lbl = LBL_DIR / f"{p.stem}.txt"
        gts = yolo_boxes(lbl) if lbl.exists() else []
        if not gts:
            continue
        im = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32) / 255.0
        ten, nw, nh, px, py = letterbox(im, input_size)
        it.set_tensor(ind["index"], ten)
        it.invoke()
        o = it.get_tensor(outd["index"])
        dets = nms(decode(
            o, input_size=input_size, new_w=nw, new_h=nh, pad_x=px, pad_y=py,
            threshold=args.low, anchor_major=anchor_major,
        ))
        flags = match_by_score(dets, gts, args.iou)
        scores = sorted((d["score"] for d in dets), reverse=True)
        per_image.append((scores, flags, len(gts)))

    total_gt = sum(n for _, _, n in per_image)
    print(f"图片 {len(per_image)} 张，人工标注共 {total_gt} 个框，"
          f"最低统计分数 {args.low}")
    print()
    print(f"{'门槛':<8}{'说出条数':<10}{'命中':<8}{'误报':<8}"
          f"{'精度':<10}{'召回':<10}")
    print("-" * 56)

    rows = []
    for t in [0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.55, 0.60, 0.65, 0.70,
              0.75, 0.80, 0.85, 0.90]:
        spoken = tp = 0
        matched_gt = 0
        for scores, flags, n_gt in per_image:
            keep = sum(1 for s in scores if s >= t)
            spoken += keep
            tp += sum(1 for s, f in zip(scores, flags) if s >= t and f)
            matched_gt += sum(1 for s, f in zip(scores, flags) if s >= t and f)
        fp = spoken - tp
        precision = tp / spoken if spoken else 0.0
        recall = matched_gt / total_gt if total_gt else 0.0
        rows.append((t, spoken, tp, fp, precision, recall))
        mark = ""
        print(f"{t:<8.2f}{spoken:<10}{tp:<8}{fp:<8}{precision:<10.3f}{recall:<10.3f}{mark}")

    ok = [r for r in rows if r[4] >= args.target_precision and r[1] > 0]
    print()
    if not ok:
        print(f"没有任何门槛达到精度 {args.target_precision:.2f}——"
              f"说明模型本身还不够好，调门槛救不了。")
        return 1
    best = ok[0]
    print(f"在精度 >= {args.target_precision:.2f} 的前提下，最低门槛 = {best[0]:.2f}"
          f"（精度 {best[4]:.3f}，召回 {best[5]:.3f}，说出 {best[1]} 条）")
    print()
    print("把它写进 `app/lib/tts/announcer.dart` 的 `kMinSpeakScore`。")
    print("注意：这只决定**说不说**；屏幕上画不画仍由界面那根滑条决定。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
