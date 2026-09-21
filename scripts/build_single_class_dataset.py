"""构建**单类**数据集：只保留一个类别，标签索引重写为 0。

## 为什么需要它

当前 24 类模型在真机上给不出可用置信度：44 张图、24 个类别（其中 20 类零样本）、
每张图 300 个候选框最高分只有 0.02–0.04。实测用 Ultralytics 预测：

    conf=0.30 -> 检出 0 个（真实标注 6 个）
    conf=0.02 -> 检出 1 个
    conf=0.01 -> 检出 3 个

框的位置其实是对的（少数检出的框与标注几乎重合），但**分类头没被训起来**，
置信度被压到任何可用阈值之下。根因是分类任务太散：24 类里 20 类一个样本都没有。

单类是对症的做法：把分类难度从 24 类降到 1 类，二值化"是不是目标"。

## 关键设计：输出 1 类，而不是 24 类

刻意**不用** `single_cls=True` 训练 24 类模型——那样输出仍是 24 通道，
首个通道对应 `footbridge_entrance`，App 会把垃圾桶标成"天橋入口"。

本脚本把标签索引**重写为 0**、`nc=1`，因此模型输出 5 通道（4+1），
Kotlin 侧按形状反推得到 `numClasses=1`，`kLabels[0]` = `footbridge_entrance`……

**这就是问题**：App 的类别表是 24 类，单类模型的 id 0 在表里是错的。

所以本脚本产出的模型**必须配一份单类映射表**，由 App 侧按模型类别数选择：
  - 模型 nc == kNumClasses  -> 用 kLabels 原样
  - 模型 nc == 1            -> 只用 kLabels[configuredClassId]

见 `app/lib/vision/single_class_map.dart`。

## 用法

    python scripts/build_single_class_dataset.py --class-id 7 --name bin
"""
from __future__ import annotations

import argparse
import csv
import json
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SRC_DATASET = REPO_ROOT / "data" / "dataset"
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def load_class_name(class_id: int) -> str:
    with CLASSES_PATH.open(encoding="utf-8") as f:
        data = json.load(f)
    for c in data["classes"]:
        if c["id"] == class_id:
            return c["name_en"]
    raise ValueError(f"类别 id {class_id} 不在 configs/classes.json 中")


def rewrite_label(text: str, keep_id: int) -> list[str]:
    """把标签里属于 keep_id 的行重写成类别 0，其余行丢弃。

    返回行列表（不含空行）。这是本脚本最容易出错的地方：YOLO 标签第一列是类别
    索引，重写错的后果是**训练照跑、指标照出**，只是类别全错。
    """
    out: list[str] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        try:
            cid = int(float(parts[0]))
            coords = [float(x) for x in parts[1:5]]
        except ValueError:
            continue
        if cid != keep_id:
            continue
        out.append("0 " + " ".join(f"{v:.6f}" for v in coords))
    return out


def find_label(src_labels: Path, rel_image: Path) -> Path | None:
    """标签镜像图像目录结构：images/<src>/<name>.jpg -> labels/<src>/<name>.txt"""
    cand = src_labels / rel_image.with_suffix(".txt")
    if cand.exists():
        return cand
    flat = src_labels / (rel_image.stem + ".txt")
    return flat if flat.exists() else None


def build(class_id: int, name: str, out_name: str | None = None) -> Path:
    src_images = SRC_DATASET / "images"
    src_labels = SRC_DATASET / "labels"
    if not src_images.exists():
        raise FileNotFoundError(f"源图像目录不存在：{src_images}")

    out_dir = REPO_ROOT / "data" / (out_name or f"dataset_single_{name}")
    if out_dir.exists():
        shutil.rmtree(out_dir)

    # manifest 从现有那份拷过来：图像集合完全相同，只有标签变了。
    src_manifest = SRC_DATASET / "manifest.csv"
    if not src_manifest.exists():
        raise FileNotFoundError(f"缺少 {src_manifest}，请先运行 make_manifest.py")

    rows: list[dict] = []
    n_imgs = n_boxes = n_dropped = 0
    with src_manifest.open(encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            rel = Path(r["image_rel"])
            src_img = src_images / rel
            if not src_img.exists():
                continue
            label_path = find_label(src_labels, rel)
            kept: list[str] = []
            if label_path is not None:
                original = label_path.read_text(encoding="utf-8")
                total = len([ln for ln in original.splitlines() if ln.strip()])
                kept = rewrite_label(original, class_id)
                n_dropped += total - len(kept)

            dst_img = out_dir / "images" / rel
            dst_img.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_img, dst_img)
            dst_lbl = out_dir / "labels" / rel.with_suffix(".txt")
            dst_lbl.parent.mkdir(parents=True, exist_ok=True)
            dst_lbl.write_text("\n".join(kept), encoding="utf-8")

            n_imgs += 1
            n_boxes += len(kept)
            rows.append({
                "image_rel": rel.as_posix(),
                "source_folder": r.get("source_folder", rel.parts[0] if len(rel.parts) > 1 else "all"),
                "route": r.get("route", "unknown"),
                "capture": r.get("capture", "video"),
                "has_label": "True",
                "has_positive": "True" if kept else "False",
                "n_boxes": str(len(kept)),
                "classes": "0" if kept else "",
            })

    with (out_dir / "manifest.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    # 单类类别表，供训练脚本用
    (out_dir / "classes.json").write_text(json.dumps({
        "version": 1,
        "note": f"单类数据集：只有 {name}（原 id {class_id}，此处重写为 0）。"
                f"由 scripts/build_single_class_dataset.py 生成。",
        "classes": [{"id": 0, "name_en": name, "name_zh": "", "group": "single",
                     "priority": "P0", "announced": True,
                     "original_id": class_id}],
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"单类数据集已生成：{out_dir.relative_to(REPO_ROOT)}")
    print(f"  保留类别 id {class_id}（{name}），重写为 0")
    print(f"  图像 {n_imgs} 张，保留标注框 {n_boxes} 个，丢弃其他类别的框 {n_dropped} 个")
    neg = sum(1 for r in rows if r["has_positive"] == "False")
    if neg:
        print(f"  其中 {neg} 张无目标（负样本，对降误报有用，予以保留）")
    return out_dir


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--class-id", type=int, required=True, help="要保留的类别 id")
    ap.add_argument("--name", default=None, help="类别英文名（默认从 classes.json 取）")
    ap.add_argument("--out", default=None, help="输出目录名（默认 dataset_single_<name>）")
    args = ap.parse_args()

    name = args.name or load_class_name(args.class_id)
    build(args.class_id, name, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
