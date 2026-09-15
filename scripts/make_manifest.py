"""扫描 data/dataset/ 生成 manifest.csv，作为划分与评测的依据。

用法：
    python scripts/make_manifest.py
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
IMAGES_DIR = DATASET_DIR / "images"
LABELS_DIR = DATASET_DIR / "labels"
MANIFEST_PATH = DATASET_DIR / "manifest.csv"

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}
MANIFEST_COLUMNS = [
    "image_rel",
    "source_folder",
    "route",
    "capture",
    "has_label",
    "has_positive",
    "n_boxes",
    "classes",
]


def parse_source_meta(source_folder: str) -> dict:
    """从来源文件夹名解析路线与采集方式。"""
    lower = source_folder.lower()
    if lower.startswith("route_a") or "_route_a" in lower:
        route = "route_A"
    elif lower.startswith("route_b") or "_route_b" in lower:
        route = "route_B"
    else:
        route = "unknown"
    capture = "photo" if "photo" in lower else "video"
    return {"route": route, "capture": capture}


def read_label_summary(label_path: Path) -> tuple[int, list[int]]:
    """返回 (框数, 排序去重后的类别 id 列表)。文件缺失返回 (-1, [])。"""
    if not label_path.exists():
        return -1, []
    classes: set[int] = set()
    n_boxes = 0
    with label_path.open(encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 5:
                continue
            try:
                classes.add(int(parts[0]))
            except ValueError:
                continue
            n_boxes += 1
    return n_boxes, sorted(classes)


def label_path_for(image_rel: str) -> Path:
    """图像相对路径 -> 标签绝对路径。

    **标签镜像图像的目录结构**，这是 Ultralytics 的硬性契约：
    `img2label_paths()` 把 `\\images\\` 替换为 `\\labels\\` 并保留其余层级，即
        images/<source_folder>/<name>.jpg
        labels/<source_folder>/<name>.txt
    若把标签扁平放在 labels/ 根下，全部标签都会被判为「找不到」，训练集实例数为 0。
    """
    return LABELS_DIR / Path(image_rel).with_suffix(".txt")


def build_rows() -> list[dict]:
    rows: list[dict] = []
    if not IMAGES_DIR.exists():
        return rows
    for source_dir in sorted(p for p in IMAGES_DIR.iterdir() if p.is_dir()):
        source = source_dir.name
        meta = parse_source_meta(source)
        for img in sorted(source_dir.rglob("*")):
            if not img.is_file() or img.suffix not in IMAGE_EXTS:
                continue
            # 相对图像根目录的 posix 路径，保留子目录层级（防止同名帧互相覆盖）
            rel = img.relative_to(IMAGES_DIR).as_posix()
            n_boxes, classes = read_label_summary(label_path_for(rel))
            rows.append({
                "image_rel": rel,
                "source_folder": source,
                "route": meta["route"],
                "capture": meta["capture"],
                "has_label": n_boxes >= 0,
                "has_positive": n_boxes > 0,
                "n_boxes": max(n_boxes, 0),
                "classes": "|".join(str(c) for c in classes),
            })
    return rows


def main() -> int:
    rows = build_rows()
    if not rows:
        print(f"未在 {IMAGES_DIR} 找到图像。请先运行 dedup.py。")
        return 1
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with MANIFEST_PATH.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=MANIFEST_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    n_missing = sum(1 for r in rows if not r["has_label"])
    n_negative = sum(1 for r in rows if r["has_label"] and not r["has_positive"])
    by_route: dict[str, int] = {}
    for r in rows:
        by_route[r["route"]] = by_route.get(r["route"], 0) + 1

    print(f"图像总数：{len(rows)}")
    for route, n in sorted(by_route.items()):
        print(f"  {route}: {n}")
    print(f"负样本（空标签）：{n_negative}")
    print(f"缺标签文件：{n_missing}")
    print(f"manifest -> {MANIFEST_PATH}")
    if n_missing:
        print("\n注意：缺标签表示尚未标注。完成标注后重新运行本脚本。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
