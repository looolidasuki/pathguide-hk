"""按「同等精确率」比较多个模型 —— 本项目唯一公平的模型比较口径。

## 为什么需要这个而不是直接比 mAP

两件事同时成立，而且都会误导：

1. **mAP 是对所有置信度阈值的积分面积**，而产品只在**一个**阈值上运行
   （播报门槛，当前 0.70）。本项目已被 mAP 骗过两次：
   poc5 的 mAP50 0.927 看起来大胜 poc3 的 0.744，但在工作点上行人召回反而更差。

2. **固定用同一个阈值比也不公平**：0.70 是在旧模型上调出来的。
   新模型的置信度分布会因为域偏移而整体下移，在同一阈值处自然说得更少——
   那是**标定**差异，不是能力差异。

所以公平做法是：让每个模型各自取到**同等精确率**的工作点，再比召回。
本项目**精度优先**（误报让视障用户对空无一物做动作，代价不对称），
所以「同等精确率」比「同等召回」更贴合产品的取舍。

用法：
    python scripts/matched_precision.py --json artifacts/metrics/backbone_sweep.json
    python scripts/matched_precision.py --json X.json --class pedestrian --targets 0.90,0.95
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(json_path: Path) -> dict:
    """读 compare_at_threshold.py 的输出：{run: {conf: {overall:…, 类名: {…}}}}"""
    d = json.loads(json_path.read_text(encoding="utf-8"))
    if not d:
        raise SystemExit(f"{json_path} 是空的")
    return d


def usable_confs(run_data: dict, cls: str) -> list[tuple[float, float, float]]:
    """返回 [(conf, P, R)]，只保留该类真的有数的阈值。"""
    out = []
    for conf_s, entry in run_data.items():
        v = entry.get(cls)
        if not v:
            continue
        out.append((float(conf_s), float(v["precision"]), float(v["recall"])))
    return sorted(out)


def best_at_target(run_data: dict, cls: str, target: float
                   ) -> tuple[float, float, float] | None:
    """在 P >= target 的阈值里，取召回最高的那个。

    注意取的是**召回最高**而不是阈值最低：PR 曲线不是单调的，
    个别阈值上精度掉到目标以下、下一个阈值又回到目标以上，是常见现象。
    """
    cands = [t for t in usable_confs(run_data, cls) if t[1] >= target]
    if not cands:
        return None
    return max(cands, key=lambda t: t[2])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--class", dest="cls", default="pedestrian",
                    help="要比的类（默认 pedestrian）")
    ap.add_argument("--targets", default="0.90,0.93,0.95,0.97",
                    help="精度目标，逗号分隔")
    ap.add_argument("--also", default="bin,bicycle",
                    help="另外也打印这些类的逐阈值表（逗号分隔，可空）")
    args = ap.parse_args()

    d = load(Path(args.json))
    runs = list(d)
    targets = [float(t) for t in args.targets.split(",") if t.strip()]

    print(f"数据：{args.json}")
    print(f"模型：{', '.join(runs)}")
    print(f"类：{args.cls}\n")

    print(f"=== {args.cls} 逐阈值 P / R ===")
    hdr = f"{'conf':<7}" + "".join(f"{r:>22}" for r in runs)
    print(hdr)
    allconf = sorted({float(c) for r in runs for c in d[r]})
    for conf in allconf:
        row = f"{conf:<7}"
        for r in runs:
            v = d[r].get(f"{conf:.2f}", {}).get(args.cls)
            row += (f"{v['precision']:>11.3f}{v['recall']:>11.3f}" if v
                    else f"{'—':>22}")
        print(row)

    print(f"\n=== 同等精确率下的 {args.cls} 召回（本项目精度优先）===")
    for target in targets:
        print(f"\n  目标 P >= {target}")
        got = {}
        for r in runs:
            t = best_at_target(d[r], args.cls, target)
            got[r] = t
            if t is None:
                print(f"    {r:<16} 网格内达不到该精度")
            else:
                print(f"    {r:<16} conf={t[0]:.2f}  P={t[1]:.3f}  R={t[2]:.3f}")
        ok = {r: t for r, t in got.items() if t}
        if len(ok) >= 2:
            best = max(ok, key=lambda r: ok[r][2])
            worst = min(ok, key=lambda r: ok[r][2])
            print(f"    -> 召回最高：{best}（{ok[best][2]:.3f}）  "
                  f"最低：{worst}（{ok[worst][2]:.3f}）  "
                  f"差 {ok[best][2]-ok[worst][2]:+.3f}")

    for extra in [c for c in args.also.split(",") if c.strip()]:
        print(f"\n=== {extra} 逐阈值 P / R ===")
        print(hdr)
        for conf in allconf:
            row = f"{conf:<7}"
            for r in runs:
                v = d[r].get(f"{conf:.2f}", {}).get(extra)
                row += (f"{v['precision']:>11.3f}{v['recall']:>11.3f}" if v
                        else f"{'—':>22}")
            print(row)
        print(f"  （若各类的实例数很少，这些数字不可引用——"
              f"实例数见 compare 时的 val 标签统计）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
