"""基于感知哈希的图像去重。

职责边界：抽帧脚本不做去重，去重完全由本脚本负责。

设计说明：去重是为了消除「同一段视频相邻帧几乎相同」造成的划分泄漏。
但刻意保留路线 B 的真实冗余——评测集若过度去重会偏乐观，失去泛化度量意义。
因此 --scope 默认为 train_only，即只对路线 A 去重。

用法：
    python scripts/dedup.py --method phash --threshold 6 --scope train_only
"""
from __future__ import annotations

import argparse
import shutil
from collections import defaultdict
from pathlib import Path

import imagehash
from PIL import Image, UnidentifiedImageError

REPO_ROOT = Path(__file__).resolve().parents[1]
FRAMES_DIR = REPO_ROOT / "data" / "frames"
RAW_DIR = REPO_ROOT / "data" / "raw"
DATASET_IMAGES = REPO_ROOT / "data" / "dataset" / "images"
DUP_DIR = REPO_ROOT / "data" / "dataset" / "_duplicates"

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}
# 路线 B 为泛化评测域，刻意保留真实冗余，不去重
EVAL_ONLY_ROUTES = {"route_B"}


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def is_duplicate(hash_bits: int, seen: list[int], threshold: int) -> bool:
    return any(hamming(hash_bits, s) <= threshold for s in seen)


def compute_hash(path: Path, method: str) -> int:
    with Image.open(path) as im:
        im = im.convert("L")
        if method == "phash":
            return int(str(imagehash.phash(im)), 16)
        if method == "dhash":
            return int(str(imagehash.dhash(im)), 16)
        if method == "ahash":
            return int(str(imagehash.average_hash(im)), 16)
        raise ValueError(f"未知 method: {method}")


def iter_images(root: Path):
    if not root.exists():
        return
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.suffix in IMAGE_EXTS:
            yield p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", default="phash", choices=["phash", "dhash", "ahash"])
    ap.add_argument("--threshold", type=int, default=6, help="汉明距离阈值，<= 阈值判为重复")
    ap.add_argument("--scope", default="train_only", choices=["train_only", "all"])
    ap.add_argument("--with-photos", action="store_true", help="同时处理 data/raw 下的照片")
    args = ap.parse_args()

    src_roots: list[Path] = []
    for route_dir in sorted(p for p in FRAMES_DIR.glob("route_*") if p.is_dir()):
        if args.scope == "train_only" and route_dir.name in EVAL_ONLY_ROUTES:
            print(f"[跳过] {route_dir.name}（评测域，保留真实冗余）")
            continue
        src_roots.append(route_dir)
    if args.with_photos:
        for route_dir in sorted(p for p in RAW_DIR.glob("route_*") if p.is_dir()):
            if args.scope == "train_only" and route_dir.name in EVAL_ONLY_ROUTES:
                continue
            src_roots.append(route_dir)

    if not src_roots:
        print("没有找到可处理的图像目录。请先运行 extract_frames.py。")
        return 1

    kept_total = dup_total = err_total = 0
    summary: dict[str, list[int]] = defaultdict(lambda: [0, 0])

    for root in src_roots:
        seen_by_source: dict[str, list[int]] = defaultdict(list)
        for img in iter_images(root):
            source = img.parent.name
            out_dir = DATASET_IMAGES / source
            out_dir.mkdir(parents=True, exist_ok=True)
            try:
                bits = compute_hash(img, args.method)
            except (UnidentifiedImageError, OSError) as exc:
                print(f"  [WARN] 无法读取 {img.name}: {exc}")
                err_total += 1
                continue

            if is_duplicate(bits, seen_by_source[source], args.threshold):
                dup_dir = DUP_DIR / source
                dup_dir.mkdir(parents=True, exist_ok=True)
                shutil.move(str(img), str(dup_dir / img.name))
                dup_total += 1
                summary[source][1] += 1
            else:
                seen_by_source[source].append(bits)
                shutil.copy2(str(img), str(out_dir / img.name))
                kept_total += 1
                summary[source][0] += 1

    for source in sorted(summary):
        k, d = summary[source]
        print(f"{source}: kept={k} dup={d}")
    print(f"\nkept={kept_total} dup={dup_total} unreadable={err_total}")
    print(f"输出：{DATASET_IMAGES}")
    print(f"重复件：{DUP_DIR}（未删除，可人工复核）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
