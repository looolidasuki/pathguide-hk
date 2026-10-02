"""在**播报门槛**处对比两版模型 —— 这才是决定「哪版该上机」的数字。

## 为什么 mAP 不够

mAP50 是对所有置信度阈值积分的面积。两版模型的 mAP50 几乎相同
（pedestrian 0.796 vs 0.817），但它们的 P/R 曲线**形状不同**：
poc4 在低阈值处召回高、在高阈值处精确率低。

而产品实际运行在**一个**阈值上：`kMinSpeakScore = 0.70`
（见 app/lib/tts/announcer.dart）。低于它的框画出来但不播报。
所以真正要问的是：「在 0.70 处，哪个模型的精确率更高？」

背景：本项目已确立「误报的代价不对称」——视障用户会照着错误播报**做动作**。
所以精确率优先于召回率，这个对比不能只看 mAP。

用法：
    python scripts/compare_at_threshold.py --data data/dataset_poc4/dataset.yaml \
        --weights runs/pg_poc3/weights/best.pt runs/pg_poc4/weights/best.pt
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

SPEAK_THRESHOLD = 0.70   # 与 app/lib/tts/announcer.dart 的 kMinSpeakScore 一致
DISPLAY_THRESHOLD = 0.30  # 与显示门槛一致
GRID = [0.30, 0.50, 0.60, 0.70, 0.80, 0.90]


def parse_grid(s: str) -> list[float]:
    """解析 --grid，如 "0.3,0.5,0.6,0.7"。

    为什么需要：比较两版模型时，**固定用门槛 0.70 是不公平的**——
    0.70 是在旧模型上调出来的。新模型的置信度分布整体下移（域偏移），
    在同一个阈值处自然会说得更少，但那是**标定**问题，不是能力退化。

    公平的做法是让两者各自取到「同等精确率」的工作点再比召回。
    要那样就必须在目标精度附近有足够密的网格。
    """
    out = []
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        out.append(float(part))
    if not out:
        raise ValueError("--grid 不能为空")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--weights", nargs="+", required=True)
    ap.add_argument("--imgsz", type=int, default=416)
    ap.add_argument("--grid", default=None,
                    help="逗号分隔的阈值网格，如 0.3,0.5,0.6,0.7。"
                         "要按「同等精确率」公平对比两版模型时，需在目标精度附近加密。")
    ap.add_argument("--out", default="artifacts/metrics/threshold_compare.json")
    args = ap.parse_args()
    grid = parse_grid(args.grid) if args.grid else GRID

    from ultralytics import YOLO

    from yolo_metrics import ap_index_of, map_per_class_metrics

    def per_class(r):
        """把逐类指标正确地对回类名。

        ★ 这里踩过：`r.names` 是 **data.yaml 的类别数**（poc5 是 18），
        而 `r.box.p` 只覆盖 **val 里真的有实例的类**（poc5 是 3），
        两者长度不等，直接 `r.box.p[i]` 会 IndexError。
        正确的映射是 `r.box.ap_class_index`。

        这个写法在 3 类模型时恰好不报错（两个长度都是 3），
        属于「靠巧合工作」——换成 18 类数据集才暴露。

        逻辑抽到 scripts/yolo_metrics.py 并由单测覆盖，
        因为这类 bug 会给出一张**错的表**而不是报错。
        """
        return map_per_class_metrics(
            r.names, r.box.p, r.box.r, r.box.ap50, r.box.ap,
            ap_class_index=ap_index_of(r),
            instances=getattr(r, "nt_per_class", None),
        )

    all_res: dict[str, dict] = {}
    for w in args.weights:
        p = Path(w)
        if not p.exists():
            print(f"跳过（不存在）：{p}")
            continue
        run_name = p.parent.parent.name
        m = YOLO(str(p))
        per_conf: dict[str, dict] = {}
        for conf in grid:
            r = m.val(data=args.data, imgsz=args.imgsz, split="val", conf=conf,
                      workers=0, plots=False, verbose=False)
            entry = {"overall": {
                "precision": round(float(r.box.mp), 4),
                "recall": round(float(r.box.mr), 4),
            }}
            entry.update(per_class(r))
            per_conf[f"{conf:.2f}"] = entry
        n_cls = len(per_class(r))      # 复用最后一次 val 的结果，不重复跑
        all_res[run_name] = per_conf
        print(f"\n{run_name} 完成（val 里 {n_cls} 个类有实例）")

    print("\n===== 在播报门槛 %.2f 处的对比 =====" % SPEAK_THRESHOLD)
    key = f"{SPEAK_THRESHOLD:.2f}"
    names = sorted({c for r in all_res.values() for c in r[key] if c != "overall"})
    print(f"{'类别':<14}" + "".join(f"{rn:>26}" for rn in all_res))
    print(f"{'':<14}" + "".join(f"{'P      R':>26}" for _ in all_res))
    for n in names:
        row = f"{n:<14}"
        for rn in all_res:
            v = all_res[rn][key].get(n)
            row += f"{v['precision']:>14.3f}{v['recall']:>12.3f}" if v else f"{'—':>26}"
        print(row)
    row = f"{'总体':<14}"
    for rn in all_res:
        v = all_res[rn][key]["overall"]
        row += f"{v['precision']:>14.3f}{v['recall']:>12.3f}"
    print(row)

    print("\n===== 各个阈值下的总体精确率（看曲线形状）=====")
    print(f"{'conf':<8}" + "".join(f"{rn:>16}" for rn in all_res))
    for conf in grid:
        k = f"{conf:.2f}"
        row = f"{k:<8}"
        for rn in all_res:
            row += f"{all_res[rn][k]['overall']['precision']:>16.4f}"
        print(row + ("   <- 播报门槛" if abs(conf - SPEAK_THRESHOLD) < 1e-9 else ""))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(all_res, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    print(f"\n已写 {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
