"""检测探针：在给定图片目录上统计每个类的检出次数。

两种用途，同一套代码：

1. **误报探测**（在 `data/dataset_poc5/images/val` 上跑）：
   这些香港街拍里没有那 15 个新类的实例，所以检出的都是误报。
   val 的 mAP 看不见这种误报（ultralytics 只对 GT 里出现过的类算 AP）。

2. **遗忘探测**（在第三方的 val 图上跑）：
   从 poc5 微调出 stage2 时，第二阶段只用香港数据（那 15 个类**一个框都没有**），
   所以很可能发生灾难性遗忘。而**香港 val 测不出来**——那里没有它们的实例。
   只能在**含有这些类的第三方图**上看检出次数有没有塌掉。

用法：
    python scripts/probe_class_detections.py --images <目录> --weights A B [C]
"""
from __future__ import annotations

import argparse
import collections
import io
from contextlib import redirect_stdout
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True, help="图片目录")
    ap.add_argument("--weights", nargs="+", required=True)
    ap.add_argument("--conf", type=float, default=0.30)
    ap.add_argument("--speak", type=float, default=0.70)
    ap.add_argument("--imgsz", type=int, default=416)
    ap.add_argument("--limit", type=int, default=0, help="只用前 N 张（0=全部）")
    args = ap.parse_args()

    imgs = sorted(p for p in Path(args.images).rglob("*")
                  if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
    if args.limit:
        step = max(1, len(imgs) // args.limit)
        imgs = imgs[::step][: args.limit]
    print(f"图片 {len(imgs)} 张（{Path(args.images)}）")
    print(f"统计阈值 conf>={args.conf}；另记 conf>={args.speak}（播报门槛）\n")

    from ultralytics import YOLO

    results: dict[str, dict[str, list[int]]] = {}
    for w in args.weights:
        p = Path(w)
        if not p.exists():
            print(f"跳过（不存在）：{p}")
            continue
        run = p.parent.parent.name
        m = YOLO(str(p))
        with redirect_stdout(io.StringIO()):
            res = m.predict([str(q) for q in imgs], imgsz=args.imgsz,
                            conf=min(args.conf, args.speak), verbose=False, device=0)
        low = collections.Counter()
        high = collections.Counter()
        for r in res:
            for b in r.boxes:
                nm = r.names[int(b.cls)]
                cf = float(b.conf)
                if cf >= args.conf:
                    low[nm] += 1
                    if cf >= args.speak:
                        high[nm] += 1
        results[run] = {"low": low, "high": high}
        print(f"{run} 完成")

    names = sorted({k for v in results.values() for k in v["low"]})
    print(f"\n{'类':<26}" + "".join(f"{r:>24}" for r in results))
    print(f"{'':<26}" + "".join(f"{'>=%.2f   >=%.2f' % (args.conf, args.speak):>24}"
                                for _ in results))
    for nm in names:
        row = f"{nm:<26}"
        for r in results:
            row += f"{results[r]['low'].get(nm,0):>12}{results[r]['high'].get(nm,0):>12}"
        print(row)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
