"""把本项目的 YOLO 标签转成 X-AnyLabeling 的 JSON，供人工复核。

## 为什么需要这个脚本

**X-AnyLabeling 的 PyPI 版（0.4.43）只能导出 YOLO、不能导入 YOLO。**
实测确认：`export_formats.py` 里有 `export_to_yolo`，但没有任何 yolo 导入代码；
它的原生标签格式是**同名 `.json`**。`yolo2xlabel` 转换命令只存在于 GitHub 主线，
不在已发布的 PyPI 包里。

所以「我们的预标注 → 人工复核」这一步需要一个 JSON 写入器。
**反向不需要**：X-AnyLabeling 的 GUI 自带 `Export Annotations > YOLO`，
所以出的时候直接在界面里导出即可，不必再写一个读取器。

## X-AnyLabeling JSON 格式（读自其 label_file.py，非猜测）

```
{
  "version": "<app 版本>",
  "flags": {},
  "shapes": [
    {"label": "bin",
     "text": "",
     "points": [[x1, y1], [x2, y2]],   # **绝对像素坐标**，不是归一化
     "shape_type": "rectangle",         # 检测框用 rectangle
     "group_id": null,
     "flags": {}}
  ],
  "imagePath": "bin (1).jpg",          # 相对标签文件所在目录
  "imageData": null,                    # null 时它按同目录 + imagePath 读图
  "imageHeight": 720,
  "imageWidth": 1280
}
```

关键点：
- `points` 是**像素绝对值**。我们的 YOLO 标签是归一化中心点+宽高，需转换。
- `imageData: null` + `imagePath` 为文件名 → 它从**标签文件同目录**读图。
  因此 JSON 必须与图片放在一起，或 imagePath 给相对路径。

用法：
    python scripts/to_xanylabeling.py --images data/dataset/images/trashbin \\
        --labels data/dataset/labels/trashbin --out data/xtest/trashbin
    # 只转换不拷贝图片（假定 out 目录已有图）
    python scripts/to_xanylabeling.py --images <dir> --labels <dir> --in-place
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
XLABEL_VERSION = "0.4.43"       # 与已装的 anylabeling 版本一致；它只做校验提示，不影响读取


def load_class_names() -> list[str]:
    with CLASSES_PATH.open(encoding="utf-8") as f:
        data = json.load(f)
    return [c["name_en"] for c in sorted(data["classes"], key=lambda c: c["id"])]


def image_size(path: Path) -> tuple[int, int]:
    from PIL import Image

    with Image.open(path) as im:
        return im.size          # (w, h)


def yolo_line_to_points(line: str, w: int, h: int) -> tuple[int, list[list[float]]] | None:
    """YOLO 一行 -> (class_id, [[x1,y1],[x2,y2]]) 绝对像素坐标。"""
    parts = line.split()
    if len(parts) < 5:
        return None
    try:
        cid = int(float(parts[0]))
        cx, cy, bw, bh = (float(x) for x in parts[1:5])
    except ValueError:
        return None
    x1 = max(0.0, (cx - bw / 2) * w)
    y1 = max(0.0, (cy - bh / 2) * h)
    x2 = min(float(w), (cx + bw / 2) * w)
    y2 = min(float(h), (cy + bh / 2) * h)
    if x2 <= x1 or y2 <= y1:
        return None
    return cid, [[round(x1, 2), round(y1, 2)], [round(x2, 2), round(y2, 2)]]


def convert_one(img_path: Path, label_path: Path, out_dir: Path,
                class_names: list[str], copy_image: bool) -> tuple[int, int]:
    """写一个同名 .json。返回 (shape 数, 越界/非法跳过数)。"""
    w, h = image_size(img_path)
    shapes: list[dict] = []
    skipped = 0
    if label_path.exists():
        for line in label_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            parsed = yolo_line_to_points(line, w, h)
            if parsed is None:
                skipped += 1
                continue
            cid, pts = parsed
            label = class_names[cid] if 0 <= cid < len(class_names) else f"class_{cid}"
            if not (0 <= cid < len(class_names)):
                skipped += 1
            shapes.append({
                "label": label,
                "text": "",
                "points": pts,
                "shape_type": "rectangle",
                "group_id": None,
                "flags": {},
            })

    data = {
        "version": XLABEL_VERSION,
        "flags": {},
        "shapes": shapes,
        "imagePath": img_path.name,
        "imageData": None,
        "imageHeight": h,
        "imageWidth": w,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    if copy_image and img_path.parent.resolve() != out_dir.resolve():
        dest = out_dir / img_path.name
        if not dest.exists():
            shutil.copy2(img_path, dest)
    (out_dir / f"{img_path.stem}.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return len(shapes), skipped


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True, help="图像目录")
    ap.add_argument("--labels", required=True,
                    help="YOLO 标签目录（与图像**同名**的 .txt）")
    ap.add_argument("--out", default=None,
                    help="输出目录。默认就地写 JSON（与图像同目录），"
                         "这也是 X-AnyLabeling 读取时最省事的结构。")
    ap.add_argument("--in-place", action="store_true",
                    help="等价于 --out 与 --images 相同且不拷贝图片")
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()

    img_dir = Path(args.images)
    lbl_dir = Path(args.labels)
    img_dir = img_dir if img_dir.is_absolute() else (REPO_ROOT / img_dir)
    lbl_dir = lbl_dir if lbl_dir.is_absolute() else (REPO_ROOT / lbl_dir)
    if not img_dir.is_dir():
        print(f"图像目录不存在：{img_dir}")
        return 1
    if not lbl_dir.is_dir():
        print(f"标签目录不存在：{lbl_dir}")
        return 1

    if args.in_place:
        out_dir = img_dir
        copy_image = False
    elif args.out:
        out_dir = Path(args.out)
        out_dir = out_dir if out_dir.is_absolute() else (REPO_ROOT / out_dir)
        copy_image = True
    else:
        out_dir = img_dir          # 默认就地
        copy_image = False

    class_names = load_class_names()
    images = sorted(p for p in img_dir.rglob("*")
                    if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
    if args.limit:
        images = images[: args.limit]
    if not images:
        print(f"未在 {img_dir} 找到图像。")
        return 1

    print(f"类别表：{len(class_names)} 类")
    print(f"图像  ：{len(images)} 张  ({img_dir})")
    print(f"标签  ：{lbl_dir}")
    print(f"输出  ：{out_dir}  {'（拷贝图像）' if copy_image else '（就地写 JSON）'}\n")

    total_shapes = total_skipped = n_done = n_empty = 0
    for img in images:
        # 标签与图像同名，但可能在子目录里
        cand = [lbl_dir / f"{img.stem}.txt", lbl_dir / img.relative_to(img_dir).with_suffix(".txt")]
        label_path = next((c for c in cand if c.exists()), cand[0])
        n_shapes, n_skip = convert_one(img, label_path, out_dir, class_names, copy_image)
        total_shapes += n_shapes
        total_skipped += n_skip
        n_done += 1
        if n_shapes == 0:
            n_empty += 1

    print(f"完成 {n_done} 张 -> {total_shapes} 个 shape")
    if n_empty:
        print(f"  其中 {n_empty} 张无框（负样本，JSON 里 shapes 为空数组——"
              f"在 X-AnyLabeling 里正常显示为无标注图）")
    if total_skipped:
        print(f"  **跳过 {total_skipped} 行**（字段数不足 / 类别 id 越界 / 框退化）")

    print(f"\n下一步：启动 X-AnyLabeling")
    print(f'  .venv-label\\Scripts\\anylabeling.exe --config "$PWD\\.anylabelingrc" '
          f'--labels "$PWD\\.anylabeling_labels.txt" "{out_dir}"')
    print("\n复核完再导出：界面里 Export Annotations > YOLO（该版本支持导出，不支持导入）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
