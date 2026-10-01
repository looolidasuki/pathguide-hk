"""诊断：那 12 个「零候选」的类，是**从不触发**，还是只是分数低于门槛？

为什么必须分开：两者的结论完全相反。

- 从不触发（最高分 ≈ 0.01）-> 零样本对这个类**没有召回**，
  只能靠实拍补数据，扫视频再多次也没用。
- 只是分数低（最高分 0.15~0.24）-> 是**门槛**问题，
  把门槛降到 0.15 就能扫出来，只是噪声会变多。

扫描报告里只统计 >= min_score 的候选，所以它无法区分这两者——
这里用很低的推理下限重跑一遍，直接看每个类的**最高分**。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import cv2

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(REPO_ROOT / "scripts" / "pipeline"))

import env_setup  # noqa: E402,F401

from label_taxonomy import LabelTaxonomy, normalize_text  # noqa: E402

WATCH = ["stairs", "footbridge_railing", "barrier_water", "step", "zebra_crossing",
         "fork_in_road", "caution_slippery", "crowds_of_people_queuing",
         "barrier_fencing", "scaffold", "road_excavation", "tree_root_on_the_road"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--frames", type=int, default=120, help="均匀抽这么多帧来看")
    ap.add_argument("--weights", default="yolov8s-world.pt")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--floor", type=float, default=0.01,
                    help="推理下限，要压到很低才能看出「从不触发」")
    args = ap.parse_args()

    tax = LabelTaxonomy()
    prompts = tax.yolo_world_prompts()
    prompt_to_id = tax.prompt_to_id()
    names = {c["id"]: c["name_en"] for c in tax.classes}
    watch_ids = {c["id"]: c["name_en"] for c in tax.classes if c["name_en"] in WATCH}
    # 对照组：已知能扫到的类，用来看噪声基线
    ref_ids = {c["id"]: c["name_en"] for c in tax.classes
               if c["name_en"] in ("bin", "pedestrian", "hand_truck")}

    from ultralytics import YOLO

    model = YOLO(args.weights)
    model.set_classes(prompts)
    idx_to_id = {i: prompt_to_id[normalize_text(p)]
                 for i, p in enumerate(prompts) if normalize_text(p) in prompt_to_id}

    cap = cv2.VideoCapture(str(REPO_ROOT / args.video))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    step = max(1, total // args.frames)
    best: dict[int, float] = {}
    seen = 0
    idx = 0
    while seen < args.frames:
        if not cap.grab():
            break
        if idx % step == 0:
            ok, frame = cap.retrieve()
            if ok:
                r = model.predict([frame], imgsz=args.imgsz, conf=args.floor,
                                  verbose=False)[0]
                if r.boxes is not None and len(r.boxes):
                    for c_i, cf in zip(r.boxes.cls.tolist(), r.boxes.conf.tolist()):
                        cid = idx_to_id.get(int(c_i))
                        if cid is not None:
                            best[cid] = max(best.get(cid, 0.0), float(cf))
                seen += 1
        idx += 1
    cap.release()

    print(f"看了 {seen} 帧（推理下限 {args.floor}），逐类最高分：")
    print(f"\n  对照组（已知能扫到）：")
    for cid, name in sorted(ref_ids.items(), key=lambda kv: -best.get(kv[0], 0.0)):
        print(f"    {name:<28}{best.get(cid, 0.0):.3f}")
    print(f"\n  扫描报告里「零候选」的 12 类：")
    for cid, name in sorted(watch_ids.items(), key=lambda kv: -best.get(kv[0], 0.0)):
        v = best.get(cid, 0.0)
        verdict = ("从不触发（≈0）-> 零样本无召回，只能实拍补"
                   if v < 0.05 else
                   "分数偏低 -> 是门槛问题，可降门槛扫"
                   if v < 0.25 else
                   "其实能到门槛以上 -> 报告里不该缺席，需复查")
        print(f"    {name:<28}{v:.3f}   {verdict}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
