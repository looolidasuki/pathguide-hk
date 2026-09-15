"""标注质量门禁：越界框、非法类别、极小框、类别分布、空标签统计。

用法：
    python scripts/check_labels.py
退出码：0 通过；2 存在致命问题。
"""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
IMAGES_DIR = DATASET_DIR / "images"
LABELS_DIR = DATASET_DIR / "labels"
REPORT_PATH = DATASET_DIR / "dataset_report.md"
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}

TINY_BOX_PX = 8.0
MIN_IMAGES_PER_CLASS = 50


def load_classes() -> list[dict]:
    with CLASSES_PATH.open(encoding="utf-8") as f:
        return sorted(json.load(f)["classes"], key=lambda c: c["id"])


def parse_box(line: str) -> tuple[int, float, float, float, float] | None:
    parts = line.split()
    if len(parts) != 5:
        return None
    try:
        return int(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]), float(parts[4])
    except ValueError:
        return None


def validate_line(line: str, n_classes: int) -> list[str]:
    """返回该行的错误列表，空列表表示合法。"""
    errors: list[str] = []
    parts = line.split()
    if len(parts) != 5:
        return [f"字段数应为 5，实际 {len(parts)}"]
    parsed = parse_box(line)
    if parsed is None:
        return ["存在非数值字段"]
    cid, cx, cy, w, h = parsed
    if not (0 <= cid < n_classes):
        errors.append(f"类别 id {cid} 超出范围 [0, {n_classes - 1}]")
    for name, val in (("cx", cx), ("cy", cy), ("w", w), ("h", h)):
        if not (0.0 <= val <= 1.0):
            errors.append(f"{name}={val} 不在 [0, 1]")
    if w <= 0.0 or h <= 0.0:
        errors.append(f"框尺寸非正：w={w}, h={h}")
    if not errors:
        x1, y1, x2, y2 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
        if x1 < -1e-6 or y1 < -1e-6 or x2 > 1 + 1e-6 or y2 > 1 + 1e-6:
            errors.append(f"框越界：({x1:.3f}, {y1:.3f})-({x2:.3f}, {y2:.3f})")
    return errors


def image_size(path: Path) -> tuple[int, int] | None:
    try:
        with Image.open(path) as im:
            return im.size
    except Exception:  # noqa: BLE001
        return None


def main() -> int:
    classes = load_classes()
    class_names = [c["name_en"] for c in classes]
    n_classes = len(classes)

    images = [p for p in IMAGES_DIR.rglob("*") if p.is_file() and p.suffix in IMAGE_EXTS]
    if not images:
        print(f"未在 {IMAGES_DIR} 找到图像。")
        return 1

    fatal: list[str] = []
    warnings: list[str] = []
    class_counts: Counter[int] = Counter()
    tiny_boxes = 0
    empty_labels = 0
    missing_labels = 0
    total_boxes = 0
    widths: list[float] = []
    heights: list[float] = []
    unreadable = 0

    for img in sorted(images):
        # 标签镜像图像目录结构（Ultralytics 的 img2label_paths 契约）：
        #   images/<source>/<name>.jpg -> labels/<source>/<name>.txt
        rel = img.relative_to(IMAGES_DIR)
        label_path = LABELS_DIR / rel.with_suffix(".txt")
        if not label_path.exists():
            missing_labels += 1
            continue
        size = image_size(img)
        if size is None:
            unreadable += 1
            continue
        iw, ih = size
        lines = [ln.strip() for ln in label_path.read_text(encoding="utf-8").splitlines() if ln.strip()]
        if not lines:
            empty_labels += 1
            continue
        for ln in lines:
            errs = validate_line(ln, n_classes)
            if errs:
                fatal.append(f"{label_path.name}: '{ln}' -> {'; '.join(errs)}")
                continue
            parsed = parse_box(ln)
            if parsed is None:
                continue
            cid, _cx, _cy, w, h = parsed
            class_counts[cid] += 1
            total_boxes += 1
            widths.append(w)
            heights.append(h)
            if min(w * iw, h * ih) < TINY_BOX_PX:
                tiny_boxes += 1

    for cid, n in class_counts.items():
        if n < MIN_IMAGES_PER_CLASS:
            warnings.append(
                f"类别 {class_names[cid]}(id={cid}) 仅 {n} 个框，低于建议下限 {MIN_IMAGES_PER_CLASS}"
            )
    for cid in range(n_classes):
        if class_counts.get(cid, 0) == 0:
            warnings.append(f"类别 {class_names[cid]}(id={cid}) 没有任何标注框")
    if missing_labels:
        warnings.append(f"{missing_labels} 张图像没有对应标签文件（标注未完成，或需生成空标签作为负样本）")
    if unreadable:
        warnings.append(f"{unreadable} 张图像无法读取")

    lines_out = [
        "# 数据集质量报告",
        "",
        f"- 图像总数：{len(images)}",
        f"- 有标注的图像：{len(images) - missing_labels - empty_labels}",
        f"- 空标签（负样本）：{empty_labels}",
        f"- 缺标签文件：{missing_labels}",
        f"- 标注框总数：{total_boxes}",
        f"- 极小框（短边 < {TINY_BOX_PX:.0f}px）：{tiny_boxes}",
        f"- 致命错误：{len(fatal)}",
        "",
        "## 类别分布",
        "",
        "| id | 类别 | 组 | 框数 |",
        "|---|---|---|---|",
    ]
    for c in classes:
        lines_out.append(
            f"| {c['id']} | {c['name_en']} | {c['group']} | {class_counts.get(c['id'], 0)} |"
        )
    lines_out += [
        "",
        "## 框尺寸（归一化）",
        "",
        f"- 宽：min={min(widths):.4f} mean={sum(widths)/len(widths):.4f} max={max(widths):.4f}" if widths else "- 宽：无数据",
        f"- 高：min={min(heights):.4f} mean={sum(heights)/len(heights):.4f} max={max(heights):.4f}" if heights else "- 高：无数据",
        "",
    ]
    if fatal:
        lines_out += ["## 致命错误（须修复后才能训练）", ""]
        lines_out += [f"- {e}" for e in fatal[:200]]
        if len(fatal) > 200:
            lines_out.append(f"- ...另有 {len(fatal) - 200} 条")
        lines_out.append("")
    if warnings:
        lines_out += ["## 警告", ""]
        lines_out += [f"- {w}" for w in warnings]
        lines_out.append("")

    REPORT_PATH.write_text("\n".join(lines_out), encoding="utf-8")

    print(f"图像 {len(images)} | 框 {total_boxes} | 空标签 {empty_labels} | 缺标签 {missing_labels}")
    print(f"致命错误 {len(fatal)} | 警告 {len(warnings)}")
    print(f"report -> {REPORT_PATH}")
    for e in fatal[:20]:
        print(f"  [FATAL] {e}")
    for w in warnings[:20]:
        print(f"  [WARN ] {w}")

    return 2 if fatal else 0


if __name__ == "__main__":
    raise SystemExit(main())
