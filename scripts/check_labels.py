"""标注质量门禁：越界框、非法类别、极小框、类别分布、空标签统计。

用法：
    python scripts/check_labels.py
退出码：0 通过；2 存在致命问题。
"""
from __future__ import annotations

import argparse
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


def load_classes(path: Path | None = None) -> list[dict]:
    """读类别表。path 为 None 时用 configs/classes.json。"""
    with (path or CLASSES_PATH).open(encoding="utf-8") as f:
        return json.load(f)["classes"]


def _load_classes_unused() -> list[dict]:
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


# 框越界的容差：越界量 ≤ 此值算「边界取整」，只计数不报错；超过才算真错误。
#
# 为什么必须区分：导出工具（Roboflow 等）用浮点写归一化坐标，
# 换算回角点会有 ~1e-6 的残差（实测中位数 5.6e-6，最大 1e-3 以内）。
# 不区分时实测得到「致命错误 75」——其中 **73 个只是取整**、只有 5 个是真越界。
# 假警报把真问题埋掉，读报告的人只有两种反应：
# 全部忽略（于是错过那 5 个）或全部当真（于是无从下手）。
#
# 1e-3 这个阈值的依据：0.1% 的图像尺寸，远低于任何真实的标注误差；
# 又比浮点残差大三个数量级。实测数据在 1e-3 与 1e-2 之间**没有样本**，
# 是个干净的分界。
OOB_TOLERANCE = 1e-3


def validate_line(line: str, n_classes: int) -> tuple[list[str], list[str]]:
    """返回 (错误列表, 提示列表)。错误为空表示这一行可用。

    提示（如边界取整）不影响可用性，调用方只计数、不逐条打印。
    """
    errors: list[str] = []
    notes: list[str] = []
    parts = line.split()
    if len(parts) != 5:
        return [f"字段数应为 5，实际 {len(parts)}"], notes
    parsed = parse_box(line)
    if parsed is None:
        return ["存在非数值字段"], notes
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
        over = max(0.0, -x1, -y1, x2 - 1.0, y2 - 1.0)
        box = f"({x1:.3f}, {y1:.3f})-({x2:.3f}, {y2:.3f})"
        if over > OOB_TOLERANCE:
            errors.append(f"框越界 {over:.4f}（超容差 {OOB_TOLERANCE}）：{box}")
        elif over > 0.0:
            notes.append(f"框越界 {over:.1e}（边界取整）：{box}")
    return errors, notes


def image_size(path: Path) -> tuple[int, int] | None:
    try:
        with Image.open(path) as im:
            return im.size
    except Exception:  # noqa: BLE001
        return None


def missing_label_fatals(n_images: int, missing: int) -> list[str]:
    """缺镜像标签何时升级为致命错误。

    Ultralytics 在标签路径镜像错误时会得到 0 实例且**不报错**。
    全缺或过半缺时必须拦下训练，不能只写警告。
    """
    if n_images <= 0 or missing <= 0:
        return []
    if missing == n_images:
        return [
            "全部图像缺少镜像标签文件（疑似 labels 未按 images/<src>/ 放置；"
            "训练会静默得到 0 实例）"
        ]
    if missing * 2 >= n_images:
        return [
            f"超过半数图像缺标签文件（{missing}/{n_images}），"
            "疑似目录结构未镜像"
        ]
    return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default=None,
                    help="要检查的数据集目录（默认 data/dataset）。"
                         "现在有多个数据集（dataset_poc3/4/5），门禁必须能指向"
                         "**实际用于训练的那一个**——否则查的是旧数据，却以为查过了。")
    ap.add_argument("--classes", default=None,
                    help="类别表（默认 configs/classes.json）。本地索引与项目 id "
                         "不同的数据集应指到它自己的 classes.json。")
    args = ap.parse_args()

    ds = Path(args.dataset) if args.dataset else DATASET_DIR
    if not ds.is_absolute():
        ds = REPO_ROOT / ds
    images_dir, labels_dir = ds / "images", ds / "labels"
    report_path = ds / "dataset_report.md"
    if not images_dir.is_dir():
        print(f"不是数据集目录（缺 images/）：{ds}")
        return 1

    classes = load_classes(Path(args.classes) if args.classes else None)
    class_names = [c["name_en"] for c in classes]
    n_classes = len(classes)
    print(f"数据集：{ds.relative_to(REPO_ROOT) if ds.is_relative_to(REPO_ROOT) else ds}"
          f"   类别表：{n_classes} 类")

    images = [p for p in images_dir.rglob("*") if p.is_file() and p.suffix in IMAGE_EXTS]
    if not images:
        print(f"未在 {images_dir} 找到图像。")
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
    rounding_notes = 0

    for img in sorted(images):
        # 标签镜像图像目录结构（Ultralytics 的 img2label_paths 契约）：
        #   images/<source>/<name>.jpg -> labels/<source>/<name>.txt
        rel = img.relative_to(images_dir)
        label_path = labels_dir / rel.with_suffix(".txt")
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
            errs, notes = validate_line(ln, n_classes)
            if notes:
                rounding_notes += 1
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
    fatal.extend(missing_label_fatals(len(images), missing_labels))
    if missing_labels and missing_labels * 2 < len(images):
        warnings.append(
            f"{missing_labels} 张图像没有对应标签文件"
            "（标注未完成，或需生成空标签作为负样本）"
        )
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
        f"- 边界取整的越界框（≤{OOB_TOLERANCE}，可忽略）：{rounding_notes}",
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

    report_path.write_text("\n".join(lines_out), encoding="utf-8")

    print(f"图像 {len(images)} | 框 {total_boxes} | 空标签 {empty_labels} | 缺标签 {missing_labels}")
    print(f"致命错误 {len(fatal)} | 警告 {len(warnings)} | "
          f"边界取整（可忽略）{rounding_notes}")
    print(f"report -> {report_path}")
    for e in fatal[:20]:
        print(f"  [FATAL] {e}")
    for w in warnings[:20]:
        print(f"  [WARN ] {w}")

    return 2 if fatal else 0


if __name__ == "__main__":
    raise SystemExit(main())
