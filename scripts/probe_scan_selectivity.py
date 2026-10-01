"""诊断：YOLO-World 零样本扫描在真实街景上到底筛掉了多少帧？

## 为什么要先量一下再改设计

扫描流水线的卖点是「只留有目标的帧」。但如果**几乎每一帧都有某个类命中**，
这个筛子就等于没筛——而现象上看不出来（它确实「按规则工作」了）。

本脚本对若干帧跑一次完整 prompt 集，打印：
  1. 每帧命中多少类、最高分多少；
  2. 关心的类别（默认 bin）在各帧的真实得分；
  3. 不同门槛下「保留帧占比」——直接回答「这个筛子有没有用」。

用法：
    python scripts/probe_scan_selectivity.py --images data/probe/streetview --limit 12
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(REPO_ROOT / "scripts" / "pipeline"))

import env_setup  # noqa: E402,F401

from label_taxonomy import LabelTaxonomy, normalize_text  # noqa: E402

IMAGE_EXTS = {".jpg", ".jpeg", ".png"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", default="data/probe/streetview")
    ap.add_argument("--limit", type=int, default=12)
    ap.add_argument("--weights", default="yolov8s-world.pt")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--scan-floor", type=float, default=0.05)
    ap.add_argument("--watch", default="bin", help="特别关注的类别 name_en")
    args = ap.parse_args()

    root = (REPO_ROOT / args.images) if not Path(args.images).is_absolute() \
        else Path(args.images)
    imgs = sorted(p for p in root.rglob("*")
                  if p.is_file() and p.suffix.lower() in IMAGE_EXTS)[: args.limit]
    if not imgs:
        print(f"没有图像：{root}")
        return 1

    tax = LabelTaxonomy()
    prompts = tax.yolo_world_prompts()
    prompt_to_id = tax.prompt_to_id()
    names = {c["id"]: c["name_en"] for c in tax.classes}
    watch_id = next((c["id"] for c in tax.classes if c["name_en"] == args.watch), None)

    from ultralytics import YOLO

    model = YOLO(args.weights)
    model.set_classes(prompts)
    idx_to_id = {}
    for i, p in enumerate(prompts):
        cid = prompt_to_id.get(normalize_text(p))
        if cid is not None:
            idx_to_id[i] = cid

    print(f"图像 {len(imgs)} 张；prompt 说法 {len(prompts)} 条；关注类 = {args.watch}")
    print(f"{'图片':<26}{'命中类数':<10}{'最高分':<10}{'总框数':<10}{args.watch + ' 的最高分'}")
    print("-" * 78)

    per_frame: list[tuple[int, float, Counter]] = []
    for p in imgs:
        r = model.predict([str(p)], imgsz=args.imgsz, conf=args.scan_floor,
                          verbose=False)[0]
        by_class: Counter[int] = Counter()
        best: dict[int, float] = {}
        if r.boxes is not None and len(r.boxes):
            for c_i, cf in zip(r.boxes.cls.tolist(), r.boxes.conf.tolist()):
                cid = idx_to_id.get(int(c_i))
                if cid is None:
                    continue
                by_class[cid] += 1
                best[cid] = max(best.get(cid, 0.0), float(cf))
        top = max(best.values()) if best else 0.0
        w = f"{best.get(watch_id, 0.0):.3f}" if watch_id is not None else "—"
        print(f"{p.name[:25]:<26}{len(by_class):<10}{top:<10.3f}"
              f"{sum(by_class.values()):<10}{w}")
        per_frame.append((len(by_class), top, by_class))

    print()
    print("不同门槛下会被保留的帧占比（衡量这个筛子到底筛掉了多少）：")
    print(f"  {'门槛':<8}{'保留帧':<10}{'占比':<10}{'说明'}")
    for thr in (0.15, 0.25, 0.35, 0.45, 0.55):
        kept = sum(1 for _, top, _ in per_frame if top >= thr)
        pct = 100 * kept / len(per_frame)
        note = "（等于没筛）" if pct >= 90 else ("（筛掉一半以上）" if pct <= 50 else "")
        print(f"  {thr:<8}{kept:<10}{pct:<10.0f}%  {note}")

    print()
    print("最常出现的类别（前 10）——街景里「什么都有」的直接证据：")
    total: Counter[int] = Counter()
    for _, _, by_class in per_frame:
        total.update(by_class)
    for cid, n in total.most_common(10):
        print(f"  {names.get(cid, cid):<28}{n:>5} 框")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
