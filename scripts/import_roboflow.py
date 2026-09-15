"""导入 Roboflow 导出的数据集（YOLO 格式），转成本项目的目录结构。

**为什么需要这个脚本：** Roboflow 导出的结构与 Ultralytics 的要求不同，直接训练会失败：

    Roboflow 导出                  本项目要求
    ───────────────                ──────────────
    train/images/xxx.jpg           images/<来源文件夹>/xxx.jpg
    train/labels/xxx.txt           labels/<来源文件夹>/xxx.txt
    valid/  test/                  （由 split_dataset.py 重新划分）
    data.yaml（path 指向它的临时目录）

两点关键差异：
1. **标签必须镜像图像的子目录**。Ultralytics 的 img2label_paths() 把路径里的
   images 段换成 labels 段并保留其余层级；若标签是扁平的，全部读不到，
   实例数为 0 且**不报错**。（本项目踩过的最贵的坑。）
2. **Roboflow 的输出会丢掉来源信息**。我们把 train/valid/test 合并回同一个
   images/ 下、按来源文件夹组织，再由 split_dataset.py 重新划分——
   因为 Roboflow 不知道哪几张来自同一采集点位，它的随机划分会造成泄漏。

用法：
    python scripts/import_roboflow.py --zip ~/Downloads/trashbin.v1i.yolov8.zip
    python scripts/import_roboflow.py --dir C:/Users/user/Downloads/trashbin.v1i.yolov8

    # 指定来源文件夹名（默认用原 Roboflow 划分名，但**建议手工指定实际点位**）
    python scripts/import_roboflow.py --dir <导出目录> --source-folder 20260920_tsk_footbridge

    # 只检查不写入
    python scripts/import_roboflow.py --dir <导出目录> --dry-run
"""
from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import zipfile
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}
SPLIT_DIRS = ("train", "valid", "val", "test")


def read_yaml_names(yaml_path: Path) -> list[str]:
    """从 Roboflow 的 data.yaml 读类别名（不依赖 pyyaml，格式简单）。"""
    names: list[str] = []
    if not yaml_path.exists():
        return names
    text = yaml_path.read_text(encoding="utf-8", errors="replace")
    in_names = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.strip().startswith("names:"):
            in_names = True
            tail = line.split("names:", 1)[1].strip()
            if tail.startswith("["):          # 单行写法 names: ['a', 'b']
                items = tail.strip("[]").split(",")
                names = [x.strip().strip("'\"") for x in items if x.strip()]
                break
            continue
        if in_names:
            if not line.startswith((" ", "\t")):
                break
            s = line.strip()
            if ":" in s:
                names.append(s.split(":", 1)[1].strip().strip("'\""))
            elif s.startswith("- "):
                names.append(s[2:].strip().strip("'\""))
    return [n for n in names if n]


def find_dataset_root(base: Path) -> Path:
    """Roboflow 的 zip 解压后通常多一层目录，找到真正含 split 子目录的那层。"""
    for c in [base] + [p for p in base.rglob("*") if p.is_dir()]:
        if any((c / s / "images").is_dir() for s in SPLIT_DIRS):
            return c
    return base


def map_class(source_names: list[str], target_classes: list[dict],
              override: dict[str, int] | None = None) -> tuple[dict[int, int], list[str]]:
    """把 Roboflow 的类别索引映射到本项目 classes.json 的 id。

    未匹配的类别**不静默丢弃**，而是报告出来——静默丢弃会让某些类的框凭空消失。
    """
    override = override or {}
    by_en = {c["name_en"].lower(): c["id"] for c in target_classes}
    mapping: dict[int, int] = {}
    unmatched: list[str] = []
    for i, nm in enumerate(source_names):
        if nm in override:
            mapping[i] = override[nm]
            continue
        key = nm.strip().lower()
        if key in by_en:
            mapping[i] = by_en[key]
            continue
        compact = key.replace(" ", "").replace("_", "").replace("-", "")
        hit = next((cid for k, cid in by_en.items()
                    if k.replace("_", "").replace(" ", "") == compact), None)
        if hit is not None:
            mapping[i] = hit
        else:
            unmatched.append(nm)
    return mapping, unmatched


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default=None, help="Roboflow 导出的 zip")
    ap.add_argument("--dir", default=None, help="已解压的导出目录")
    ap.add_argument("--out", default="data/dataset",
                    help="输出根目录（默认 data/dataset，即流水线的事实源）")
    ap.add_argument("--source-folder", default=None,
                    help="来源文件夹名（分组划分的键）。不指定时用 Roboflow 的 split 名。"
                         "**建议指定实际采集点位**，否则同一批照片会被当成同一来源。")
    ap.add_argument("--class-override", default=None,
                    help='JSON 映射，处理类别名对不上的情况，如 {"bin": 7}')
    ap.add_argument("--dry-run", action="store_true", help="只检查与报告，不写入")
    ap.add_argument("--clear", action="store_true",
                    help="写入前清空输出目录的 images/ 与 labels/")
    args = ap.parse_args()

    if not args.zip and not args.dir:
        print("请指定 --zip 或 --dir")
        return 1

    tmp: Path | None = None
    if args.zip:
        z = Path(args.zip).expanduser()
        if not z.exists():
            print(f"未找到 zip：{z}")
            return 1
        (REPO_ROOT / ".tmp").mkdir(parents=True, exist_ok=True)
        tmp = Path(tempfile.mkdtemp(prefix="rf_import_", dir=str(REPO_ROOT / ".tmp")))
        with zipfile.ZipFile(z) as zf:
            zf.extractall(tmp)
        base = tmp
        print(f"已解压：{z.name}")
    else:
        base = Path(args.dir).expanduser()
        if not base.exists():
            print(f"未找到目录：{base}")
            return 1

    root = find_dataset_root(base)
    print(f"数据集根：{root}")

    with CLASSES_PATH.open(encoding="utf-8") as f:
        target_classes = sorted(json.load(f)["classes"], key=lambda c: c["id"])

    yaml_path = next((root / n for n in ("data.yaml", "data.yml", "dataset.yaml")
                      if (root / n).exists()), None)
    source_names = read_yaml_names(yaml_path) if yaml_path else []
    print(f"\nRoboflow 声明类别 {len(source_names)} 个："
          + (", ".join(source_names) if source_names else "(未找到 data.yaml)"))

    override = json.loads(args.class_override) if args.class_override else {}
    mapping, unmatched = map_class(source_names, target_classes, override)
    if mapping:
        print("\n类别映射：")
        for i in sorted(mapping):
            tgt = next(c for c in target_classes if c["id"] == mapping[i])
            print(f"  {i:>3} {source_names[i]:<26} -> {tgt['id']:>3} {tgt['name_en']}")
    if unmatched:
        print(f"\n[警告] 以下类别无法映射，其框将被跳过（{len(unmatched)} 个）：")
        for nm in unmatched:
            print(f"  - {nm}")
        print('  用 --class-override \'{"名字": 目标id}\' 指定映射')

    pairs: list[tuple[Path, Path, str]] = []
    per_split: Counter[str] = Counter()
    for split in SPLIT_DIRS:
        img_dir = root / split / "images"
        lbl_dir = root / split / "labels"
        if not img_dir.is_dir():
            continue
        for img in sorted(img_dir.rglob("*")):
            if not img.is_file() or img.suffix.lower() not in IMAGE_EXTS:
                continue
            lbl = lbl_dir / img.relative_to(img_dir).with_suffix(".txt")
            pairs.append((img, lbl, split))
            per_split[split] += 1

    if not pairs:
        print(f"\n在 {root} 下未找到任何 train/valid/test 的 images/")
        print("请确认导出时选了 YOLO 格式。")
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
        return 1

    print(f"\n共找到 {len(pairs)} 张图像：")
    for s, n in per_split.items():
        print(f"  {s:<8} {n}")

    box_by_class: Counter[int] = Counter()
    unmapped_boxes = 0
    empty_labels = 0
    missing_labels = 0
    for img, lbl, _ in pairs:
        if not lbl.exists():
            missing_labels += 1
            continue
        lines = [x for x in lbl.read_text(encoding="utf-8").splitlines() if x.strip()]
        if not lines:
            empty_labels += 1
            continue
        for ln in lines:
            parts = ln.split()
            if len(parts) < 5:
                continue
            try:
                src_id = int(float(parts[0]))
            except ValueError:
                continue
            if src_id in mapping:
                box_by_class[mapping[src_id]] += 1
            else:
                unmapped_boxes += 1

    print(f"\n框统计：{sum(box_by_class.values())} 个已映射"
          + (f"，{unmapped_boxes} 个因类别未映射被跳过" if unmapped_boxes else ""))
    print(f"空标签（负样本）：{empty_labels}    缺标签文件：{missing_labels}")
    print(f"\n{'id':>3} {'类别':<24} {'框数':>6}")
    for cid in sorted(box_by_class):
        nm = next(c["name_en"] for c in target_classes if c["id"] == cid)
        print(f"{cid:>3} {nm:<24} {box_by_class[cid]:>6}")
    zero = [c["name_en"] for c in target_classes if not box_by_class.get(c["id"])]
    if zero:
        print(f"\n零框类别（{len(zero)}）：{', '.join(zero)}")

    if args.dry_run:
        print("\n--dry-run：未写入任何文件。")
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
        return 0

    out_root = REPO_ROOT / args.out
    images_out = out_root / "images"
    labels_out = out_root / "labels"
    if args.clear:
        for d in (images_out, labels_out):
            if d.exists():
                shutil.rmtree(d)
    images_out.mkdir(parents=True, exist_ok=True)
    labels_out.mkdir(parents=True, exist_ok=True)

    n_img = n_lbl = n_box = 0
    collisions: list[str] = []
    for img, lbl, split in pairs:
        # 来源文件夹 = 分组划分的键。未指定时退化为 Roboflow 的 split 名，可接受但不理想。
        src_folder = args.source_folder or f"roboflow_{split}"
        (images_out / src_folder).mkdir(parents=True, exist_ok=True)
        (labels_out / src_folder).mkdir(parents=True, exist_ok=True)

        dest_img = images_out / src_folder / img.name
        if dest_img.exists() and dest_img.stat().st_size != img.stat().st_size:
            collisions.append(img.name)
        shutil.copy2(img, dest_img)
        n_img += 1

        dest_lbl = labels_out / src_folder / f"{img.stem}.txt"
        if lbl.exists():
            out_lines = []
            for ln in lbl.read_text(encoding="utf-8").splitlines():
                parts = ln.split()
                if len(parts) < 5:
                    continue
                try:
                    src_id = int(float(parts[0]))
                except ValueError:
                    continue
                if src_id not in mapping:
                    continue
                out_lines.append(f"{mapping[src_id]} " + " ".join(parts[1:5]))
                n_box += 1
            dest_lbl.write_text("\n".join(out_lines) + ("\n" if out_lines else ""),
                                encoding="utf-8")
        else:
            # 缺标签文件时写空文件：空标签 = 有效负样本，与缺文件语义不同
            dest_lbl.write_text("", encoding="utf-8")
        n_lbl += 1

    print(f"\n写入完成：{n_img} 图 / {n_lbl} 标签 / {n_box} 框")
    print(f"  -> {images_out.relative_to(REPO_ROOT)}")
    print(f"  -> {labels_out.relative_to(REPO_ROOT)}")
    if collisions:
        print(f"\n[警告] {len(collisions)} 张同名文件被覆盖（不同 split 下同名）：")
        for n in collisions[:5]:
            print(f"  - {n}")
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n下一步：")
    print("  python scripts\\make_manifest.py")
    print("  python scripts\\split_dataset.py --seed 42")
    print("  python scripts\\check_labels.py")
    print("  python scripts\\run_pipeline.py --skip-generate --epochs 100 --workers 4")
    print("\n注意：Roboflow 的 train/valid/test 划分已被合并，")
    print("      划分交由 split_dataset.py 按来源分组重做（防止同源泄漏）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
