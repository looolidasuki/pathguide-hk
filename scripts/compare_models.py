"""在**同一个**验证集上对比两版权重，用于回答「加 Roboflow 数据到底有没有用」。

## 为什么必须同一个验证集

`runs/pg_poc3` 与 `runs/pg_poc4` 各自的 val 划分不同（数据不同、切分不同），
直接比各自的 mAP 是**不可比**的：差异里混了「验证集变了」这一项。

而两个数据集的本地索引顺序恰好一致（0=pedestrian, 1=bicycle, 2=bin），
所以可以让两个模型都跑 `dataset_poc4` 的 val —— 那个 val **100% 是香港实拍，
不含 Roboflow 数据**（Roboflow 走 --add-train-only）。于是：

  - 对比是公平的（同数据、同划分）
  - 数字有意义的（val 无第三方数据、无同源泄漏）

用法：
    python scripts/compare_models.py --data data/dataset_poc4/dataset.yaml \
        --weights runs/pg_poc3/weights/best.pt runs/pg_poc4/weights/best.pt
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--weights", nargs="+", required=True)
    ap.add_argument("--imgsz", type=int, default=416)
    ap.add_argument("--out", default="artifacts/metrics/compare.json")
    args = ap.parse_args()

    from ultralytics import YOLO

    results = {}
    for w in args.weights:
        p = Path(w)
        if not p.exists():
            print(f"跳过（不存在）：{p}")
            continue
        m = YOLO(str(p))
        r = m.val(data=args.data, imgsz=args.imgsz, split="val",
                  workers=0, plots=False, verbose=False)
        per = {}
        for i, name in r.names.items():
            per[name] = {
                "precision": round(float(r.box.p[i]), 4),
                "recall": round(float(r.box.r[i]), 4),
                "mAP50": round(float(r.box.ap50[i]), 4),
                "mAP50_95": round(float(r.box.ap[i]), 4),
            }
        results[p.parent.parent.name] = {
            "weights": str(p),
            "data": args.data,
            "imgsz": args.imgsz,
            "overall": {
                "precision": round(float(r.box.mp), 4),
                "recall": round(float(r.box.mr), 4),
                "mAP50": round(float(r.box.map50), 4),
                "mAP50_95": round(float(r.box.map), 4),
            },
            "per_class": per,
        }
        print(f"\n{p.parent.parent.name}  总体 {results[p.parent.parent.name]['overall']}")
        for k, v in per.items():
            print(f"  {k:<12} {v}")

    if len(results) >= 2:
        runs = list(results)
        print("\n===== 逐类对比（同一验证集）=====")
        names = sorted({c for r in results.values() for c in r["per_class"]})
        for n in names:
            print(f"\n  {n}")
            for rn in runs:
                v = results[rn]["per_class"].get(n)
                if v is None:
                    print(f"    {rn:<14} （该模型无此类）")
                    continue
                print(f"    {rn:<14} P={v['precision']:.3f} R={v['recall']:.3f} "
                      f"mAP50={v['mAP50']:.3f} mAP50-95={v['mAP50_95']:.3f}")
        # 关键指标：bicycle
        print("\n  >>> bicycle 的变化（本项目的死角）：")
        for rn in runs:
            v = results[rn]["per_class"].get("bicycle")
            if v:
                print(f"    {rn:<14} mAP50={v['mAP50']:.3f}  R={v['recall']:.3f}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    print(f"\n已写 {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
