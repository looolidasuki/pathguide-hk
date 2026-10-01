"""评估：COCO 预训练模型自带哪些类能直接用于本项目的 48 类表？

## 为什么值得量一下

有人会问：「行人类别为什么不直接用 COCO 自带的 person？那不就省掉训练了？」
这个想法对不对，取决于**自带的类能覆盖我们多少类**，以及**域偏移有多大**。
两件事都不该凭印象回答：

1. 我们用 YOLO11n 从 COCO 权重微调而来，所以 `yolo11n.pt` 的 `model.names`
   就是权威的 COCO 类名表——直接读它，不靠记忆。
2. 域偏移可以量：在香港步行视频上跑 COCO 的 person，看触发率与每帧人数。
   COCO 的照片多为欧美场景，而部署是香港街景、手机竖屏视角。

用法：
    python scripts/probe_coco_overlap.py --video data/raw/myVideo/<片名>.mp4 --frames 150
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import env_setup  # noqa: E402,F401  导入即生效（必须在 ultralytics 之前）

import cv2  # noqa: E402

# 我们的类名 -> COCO 里可能对应的说法（人工建立，只在确认同名或同义时写进来）
COCO_SYNONYMS = {
    "pedestrian": ["person"],
    "bicycle": ["bicycle"],
    "table": ["dining table", "chair"],
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="yolo11n.pt",
                    help="COCO 预训练权重（就是从它微调的）")
    ap.add_argument("--video", default=None, help="可选：跑一段香港街景看域偏移")
    ap.add_argument("--frames", type=int, default=150)
    ap.add_argument("--conf", type=float, default=0.25)
    args = ap.parse_args()

    from ultralytics import YOLO

    model = YOLO(args.weights)
    coco = {str(v).lower(): k for k, v in model.names.items()}
    print(f"COCO 类数：{len(coco)}")

    import json
    cur = json.loads((REPO_ROOT / "configs" / "classes.json").read_text(encoding="utf-8"))
    ours = [c["name_en"] for c in sorted(cur["classes"], key=lambda c: c["id"])]
    print(f"本项目类数：{len(ours)}")

    hit, fuzzy = [], []
    for name in ours:
        if name in coco:
            hit.append(name)
        elif name in COCO_SYNONYMS:
            fuzzy.append((name, COCO_SYNONYMS[name]))
    print(f"\n完全同名的：{hit or '无'}")
    print(f"语义相近的（需要人工确认是否够用）：{fuzzy or '无'}")
    covered = {n for n in hit} | {n for n, _ in fuzzy}
    print(f"\n★ 结论：48 类里，COCO 自带能覆盖的最多是 {len(covered)} 个："
          f"{sorted(covered)}")
    print(f"   剩下 {len(ours) - len(covered)} 类 COCO 里根本没有——"
          f"这些类仍然必须自己训练。")

    if not args.video:
        return 0

    # ---- 域偏移：COCO person 在香港街景上的行为 ----
    pid = coco.get("person")
    if pid is None:
        print("权重里没有 person 类，跳过域偏移检查")
        return 0

    cap = cv2.VideoCapture(str(REPO_ROOT / args.video))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    step = max(1, total // args.frames)
    counts, confs, idx, seen = [], [], 0, 0
    while seen < args.frames:
        if not cap.grab():
            break
        if idx % step == 0:
            ok, frame = cap.retrieve()
            if ok:
                r = model.predict([frame], imgsz=640, conf=args.conf,
                                  classes=[pid], verbose=False)[0]
                n = 0 if r.boxes is None else len(r.boxes)
                counts.append(n)
                if r.boxes is not None and n:
                    confs.extend(r.boxes.conf.tolist())
                seen += 1
        idx += 1
    cap.release()

    if not counts:
        print("没取到帧")
        return 0
    import statistics
    with_person = sum(1 for c in counts if c > 0)
    print(f"\n=== COCO person 在香港街景上的表现（{len(counts)} 帧, conf>={args.conf}）===")
    print(f"  有人的帧：{with_person}/{len(counts)}（{100 * with_person / len(counts):.0f}%）")
    print(f"  每帧人数：中位 {statistics.median(counts):.0f}，"
          f"最多 {max(counts)}，平均 {statistics.mean(counts):.1f}")
    if confs:
        print(f"  置信度：中位 {statistics.median(confs):.3f}，"
              f"最低 {min(confs):.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
