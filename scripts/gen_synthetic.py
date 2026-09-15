"""生成微型合成数据集，用于端到端跑通训练流水线。

用途：在真人采集开始之前，验证 数据 → 划分 → 训练 → 评测 → 导出 全链路可用。

**警告：这里生成的是合成图像，只能用于验证流水线，绝不可用于训练交付模型。**
生成的来源文件夹名以 `synthetic` 标记，实物数据到位后应清空 data/dataset/ 重新走一遍。

用法：
    python scripts/gen_synthetic.py --per-class 12 --out-size 640x480
"""
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
IMAGES_DIR = DATASET_DIR / "images"
LABELS_DIR = DATASET_DIR / "labels"
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"

SYNTHETIC_TAG = "synthetic"

# 每类一个固定基色，使合成目标在视觉上可区分（仅为了流水线可跑通）
CLASS_BASE_COLORS = [
    (220, 40, 40), (40, 200, 60), (40, 90, 230), (230, 190, 30),
    (190, 40, 210), (30, 200, 200), (240, 130, 20), (110, 70, 40),
    (140, 140, 140), (255, 255, 255), (250, 220, 90), (20, 20, 20),
    (60, 160, 120), (170, 120, 220), (100, 200, 255), (230, 90, 140),
]


def load_class_ids() -> list[int]:
    with CLASSES_PATH.open(encoding="utf-8") as f:
        data = json.load(f)
    return [c["id"] for c in sorted(data["classes"], key=lambda c: c["id"])]


def draw_scene(
    rng: random.Random,
    width: int,
    height: int,
    class_ids: list[int],
    boxes_per_image: int,
) -> tuple[Image.Image, list[tuple[int, float, float, float, float]]]:
    """绘制一张含若干彩色矩形的合成图，返回图像与 YOLO 格式标注。"""
    bg = (
        rng.randint(20, 200),
        rng.randint(20, 200),
        rng.randint(20, 200),
    )
    img = Image.new("RGB", (width, height), bg)
    draw = ImageDraw.Draw(img)

    # 背景纹理，避免整图平坦（否则拉普拉斯方差过低会被当成模糊帧）
    for _ in range(40):
        x0 = rng.randint(0, width - 1)
        y0 = rng.randint(0, height - 1)
        draw.line([(x0, y0), (x0 + rng.randint(-30, 30), y0 + rng.randint(-30, 30))],
                  fill=(rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)), width=1)

    labels: list[tuple[int, float, float, float, float]] = []
    occupied: list[tuple[int, int, int, int]] = []

    for _ in range(boxes_per_image):
        cid = rng.choice(class_ids)
        bw = rng.randint(int(width * 0.12), int(width * 0.40))
        bh = rng.randint(int(height * 0.12), int(height * 0.40))
        x0 = rng.randint(0, max(0, width - bw))
        y0 = rng.randint(0, max(0, height - bh))
        # 与已有框重叠超过一半则丢弃，避免标注歧义
        if any(_overlap_ratio((x0, y0, x0 + bw, y0 + bh), ob) > 0.5 for ob in occupied):
            continue
        occupied.append((x0, y0, x0 + bw, y0 + bh))

        base = CLASS_BASE_COLORS[cid % len(CLASS_BASE_COLORS)]
        jitter = tuple(min(255, max(0, c + rng.randint(-25, 25))) for c in base)
        draw.rectangle([x0, y0, x0 + bw, y0 + bh], fill=jitter, outline=(0, 0, 0), width=3)
        # 内部再加一个对比色小块，增加纹理
        draw.rectangle(
            [x0 + bw // 4, y0 + bh // 4, x0 + 3 * bw // 4, y0 + 3 * bh // 4],
            outline=(255 - jitter[0], 255 - jitter[1], 255 - jitter[2]), width=2,
        )

        cx = (x0 + bw / 2) / width
        cy = (y0 + bh / 2) / height
        labels.append((cid, cx, cy, bw / width, bh / height))

    return img, labels


def _overlap_ratio(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> float:
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    area_a = max(1, (a[2] - a[0]) * (a[3] - a[1]))
    return inter / area_a


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-class", type=int, default=24, help="轮次数，决定每类的目标出现次数")
    ap.add_argument("--out-size", default="640x480", help="图像尺寸 WxH")
    ap.add_argument("--sources", type=int, default=8, help="来源文件夹数量（用于分组划分）")
    ap.add_argument("--route", default="route_A", choices=["route_A", "route_B"])
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    width, height = (int(x) for x in args.out_size.lower().split("x"))
    class_ids = load_class_ids()
    rng = random.Random(args.seed)

    IMAGES_DIR.mkdir(parents=True, exist_ok=True)
    LABELS_DIR.mkdir(parents=True, exist_ok=True)

    # 目录分布：把每轮的目标轮转切片给不同来源，使各来源的类别集合不同。
    # 这一点很重要——若所有来源含完全相同的类别集合，划分脚本会把它们归入同一个
    # 分层桶，桶内前两个来源被固定分给 val/test，导致 train 几乎无正样本。
    plan: list[list[int]] = []
    for i in range(args.per_class):
        shuffled = class_ids[:]
        rng.shuffle(shuffled)
        plan.append(shuffled)

    total_images = 0
    total_boxes = 0
    per_class_count = {cid: 0 for cid in class_ids}

    for si in range(args.sources):
        source = f"{args.route}_{SYNTHETIC_TAG}_src{si:02d}"
        out_dir = IMAGES_DIR / source
        out_dir.mkdir(parents=True, exist_ok=True)
        # 标签必须**镜像**图像的子目录结构：
        #   img2label_paths() 把 `\images\` 换成 `\labels\`，保留其余层级，
        #   即 labels/<source>/<name>.txt。扁平放会导致全部标签读不到。
        lbl_dir = LABELS_DIR / source
        lbl_dir.mkdir(parents=True, exist_ok=True)

        # 每个来源只取轮转后的一个切片，保证类别集合随来源变化
        for pi, shuffled in enumerate(plan):
            if pi % args.sources != si:
                continue
            k = len(shuffled)
            start = (si * k) // args.sources
            end = ((si + 1) * k) // args.sources
            targets = shuffled[start:end] or shuffled[:1]
            img, labels = draw_scene(rng, width, height, targets, boxes_per_image=rng.randint(3, 6))
            name = f"{source}_{pi:04d}.jpg"
            img.save(out_dir / name, quality=92)

            label_lines = []
            for cid, cx, cy, w, h in labels:
                label_lines.append(f"{cid} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
                per_class_count[cid] = per_class_count.get(cid, 0) + 1
            (lbl_dir / f"{Path(name).stem}.txt").write_text(
                "\n".join(label_lines) + ("\n" if label_lines else ""), encoding="utf-8"
            )
            total_images += 1
            total_boxes += len(labels)

    # 少量负样本（空标签），验证"空标签文件 ≠ 缺标签文件"的处理
    neg_source = f"{args.route}_{SYNTHETIC_TAG}_negatives"
    neg_dir = IMAGES_DIR / neg_source
    neg_dir.mkdir(parents=True, exist_ok=True)
    neg_lbl_dir = LABELS_DIR / neg_source
    neg_lbl_dir.mkdir(parents=True, exist_ok=True)
    for i in range(6):
        img, _ = draw_scene(rng, width, height, class_ids=[], boxes_per_image=0)
        name = f"{neg_source}_{i:04d}.jpg"
        img.save(neg_dir / name, quality=92)
        (neg_lbl_dir / f"{Path(name).stem}.txt").write_text("", encoding="utf-8")
        total_images += 1

    print(f"合成图像：{total_images} 张（含 6 张负样本），标注框：{total_boxes} 个")
    print(f"来源文件夹：{args.sources} 个正样本来源 + 1 个负样本来源")
    print(f"图像 -> {IMAGES_DIR}")
    print(f"标签 -> {LABELS_DIR}")
    missing = [cid for cid, n in per_class_count.items() if n == 0]
    if missing:
        print(f"\n注意：以下类别未生成任何框（请提高 --per-class）：{missing}")
    print("\n提醒：这是合成数据，仅用于验证流水线，不可用于训练交付模型。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
