"""把 COCO 预训练模型的某一类，转成本项目格式的 YOLO 数据集（当「标注老师」用）。

## 为什么需要它

COCO 自带的 80 类里，和我们 48 类表真正对得上的只有 3 个（`bicycle` 同名、
`pedestrian`↔`person`、`table`↔`dining table`/`chair`）。但这 3 个恰恰是
**数据量最大、标注最贵**的类——实测行人出框率 96%、中位 5 个/帧。

所以正确用法不是「运行时跑两个模型」（那会把 268 ms/帧 的预算翻倍，
还多一套类别索引契约），而是：

    用 COCO 在 HK 帧上预出框 -> 人工只修边界 -> 训进我们自己的单一模型

这样运行时仍然只有一个模型，但白拿了 COCO 在 person 上几十万实例的知识。

## 产品边界（重要，写在产出里）

- **这产生的标签继承 COCO 的全部错误与偏置**：遮挡、背影、雨伞下的人、
  以及欧美人像的分布。它适合当**冷启动**，不适合当最终标注。
- 因此产出目录里会写一份 `README.md` 说明来源与局限，并**默认按时间顺序切分**
  （不是随机切分）：相邻帧几乎一样，随机切分会让验证集混进训练集的近邻，
  指标虚高——本项目在单源数据上已经踩过这个坑。

## 用法

    python scripts/coco_to_our_labels.py --images data/frames/selected/myVideo \
        --coco-class person --our-class pedestrian --out data/dataset_person_poc

    python scripts/coco_to_our_labels.py --images <dir> --coco-class bicycle \
        --our-class bicycle --out data/dataset_bicycle_poc --conf 0.4
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import env_setup  # noqa: E402,F401  导入即生效（必须在 ultralytics 之前）

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True, help="输入图像目录（递归）")
    ap.add_argument("--coco-class", required=True, help="COCO 里的类名，如 person")
    ap.add_argument("--our-class", required=True, help="本项目类名，如 pedestrian")
    ap.add_argument("--out", required=True, help="输出数据集目录")
    ap.add_argument("--weights", default="yolo11n.pt", help="COCO 预训练权重")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=0.35,
                    help="★ 老师的置信度下限。越低召回越高、噪声也越多；"
                         "COCO person 在 HK 街景实测中位 0.655，0.35 是较稳的起点")
    ap.add_argument("--val-ratio", type=float, default=0.2,
                    help="按**时间顺序**切出的验证集比例（不是随机切）")
    ap.add_argument("--limit", type=int, default=None, help="只处理前 N 张（试跑）")
    args = ap.parse_args()

    from ultralytics import YOLO

    images_root = Path(args.images)
    if not images_root.is_absolute():
        images_root = REPO_ROOT / images_root
    images = sorted(p for p in images_root.rglob("*")
                    if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
    if args.limit:
        images = images[: args.limit]
    if not images:
        print(f"没有图像：{images_root}")
        return 1

    out = Path(args.out)
    if not out.is_absolute():
        out = REPO_ROOT / out
    if out.exists():
        shutil.rmtree(out)
    # ★ 用**标准目录布局**（images/train、labels/train），不用 train.txt 列表。
    #
    # 踩过的坑：ultralytics 对 txt 列表里的相对路径是**按当前工作目录**解析的，
    # 不是按 yaml 的 `path`。于是 `images/xxx.jpg` 全部找不到，
    # 488 张被判 corrupt → `RuntimeError: No valid images found`，
    # 而报错信息只说「标签格式不对」，完全不提路径，极难自查。
    for sub in ("train", "val"):
        (out / "images" / sub).mkdir(parents=True)
        (out / "labels" / sub).mkdir(parents=True)

    model = YOLO(args.weights)
    coco_names = {str(v).lower(): k for k, v in model.names.items()}
    cid = coco_names.get(args.coco_class.lower())
    if cid is None:
        print(f"COCO 权重里没有 {args.coco_class}；可用类名有：{sorted(coco_names)}")
        return 1

    # 我们的类别 id：从 configs/classes.json 查，保证与 App 的索引一致
    cfg = json.loads((REPO_ROOT / "configs" / "classes.json").read_text(encoding="utf-8"))
    our_id = next((c["id"] for c in cfg["classes"] if c["name_en"] == args.our_class), None)
    if our_id is None:
        print(f"本项目类别表里没有 {args.our_class}")
        return 1

    print(f"老师：COCO {args.coco_class}(id {cid})  ->  本类："
          f"{args.our_class}(原 id {our_id})，conf>={args.conf}")
    print(f"图像 {len(images)} 张（按文件名顺序 = 按时间顺序）")

    n_boxes = 0
    written = 0
    kept: list[tuple[Path, str]] = []      # (原图, 安全文件名 stem)
    for p in images:
        r = model.predict([str(p)], imgsz=args.imgsz, conf=args.conf,
                          classes=[cid], verbose=False)[0]
        lines = []
        if r.boxes is not None and len(r.boxes):
            for box in r.boxes.xywhn.tolist():      # 归一化 xywh，直接就是 YOLO 格式
                # ★ 这里写 **0**，不是 our_id。
                #
                # 本数据集只训练这一类，yaml 里声明 `0: <our_class>`，
                # 而 YOLO 只接受 0..nc-1 的类 id：写 6 会让 ultralytics 判定
                # 「标签格式非法」并把**全部**样本丢弃（表现为
                # RuntimeError: No valid images found），一张都不训。
                # 这与项目里单类模型的做法一致：本地索引从 0 起，
                # 原 id 记在 classes.json 的 original_id 里，由 App 侧做偏移映射。
                lines.append(f"0 {box[0]:.6f} {box[1]:.6f} {box[2]:.6f} {box[3]:.6f}")
        # 只保留有目标的帧：没有目标的纯背景帧对「学这一类」没有价值，
        # 反而会把正样本比例拉低。（若要教模型「什么不是」，另说。）
        if not lines:
            continue
        # 文件名里的空格与逗号会被某些工具链切断（本项目已两次踩到：
        # objective_c 的构建钩子、以及 cmd 的引号解析）。这里统一清成安全字符，
        # 改名对照写进 rename_map.csv，来源仍然可追。
        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", p.stem)
        safe = re.sub(r"_{2,}", "_", safe)[:120]
        kept.append((p, safe))
        (out / "labels_tmp").mkdir(exist_ok=True)
        (out / "labels_tmp" / f"{safe}.txt").write_text("\n".join(lines) + "\n",
                                                        encoding="utf-8")
        n_boxes += len(lines)
        written += 1

    # 时间顺序切分（不是随机）
    n_val = max(1, int(len(kept) * args.val_ratio)) if len(kept) > 1 else 0
    cut = len(kept) - n_val
    splits = {"train": kept[:cut], "val": kept[cut:]}
    for split, items in splits.items():
        for src, safe in items:
            shutil.copy2(src, out / "images" / split / f"{safe}{src.suffix}")
            shutil.move(str(out / "labels_tmp" / f"{safe}.txt"),
                        str(out / "labels" / split / f"{safe}.txt"))
    (out / "labels_tmp").rmdir()
    with (out / "rename_map.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["split", "dataset_name", "source_path"])
        for split, items in splits.items():
            for src, safe in items:
                w.writerow([split, f"{safe}{src.suffix}", str(src)])

    classes_json = {
        "version": 1,
        "note": f"由 COCO {args.coco_class} 自动标注生成（scripts/coco_to_our_labels.py）。"
                f"标签继承 COCO 的错误与偏置，仅作冷启动。"
                f"本地索引为 0；original_id 是它在 configs/classes.json 里的真实 id，"
                f"训练/导出后由 App 侧做偏移映射（与单类模型同一机制）。",
        "classes": [{"id": 0, "name_en": args.our_class, "name_zh": "",
                     "group": "poc", "priority": "P0", "announced": True,
                     "original_id": our_id,
                     "coco_class": args.coco_class, "conf": args.conf}],
    }
    (out / "classes.json").write_text(
        json.dumps(classes_json, ensure_ascii=False, indent=2), encoding="utf-8")

    yaml_text = (
        f"# 由 scripts/coco_to_our_labels.py 生成\n"
        f"# 标签来自 COCO {args.coco_class}（conf>={args.conf}），仅作冷启动\n"
        f"# 用标准目录布局而不是 train.txt 列表：ultralytics 会把 txt 里的相对路径\n"
        f"# 按**当前工作目录**解析（不是按 path），导致全部图找不到且报错信息与路径无关。\n"
        f"path: {out.as_posix()}\n"
        f"train: images/train\n"
        f"val: images/val\n"
        f"names:\n  0: {args.our_class}\n"
    )
    (out / "dataset.yaml").write_text(yaml_text, encoding="utf-8")

    (out / "README.md").write_text(
        f"""# {args.our_class} 冷启动数据集（COCO 自动标注）

- 老师：`{args.weights}` 的 `{args.coco_class}` 类（conf >= {args.conf}）
- 本类 id：本地 `0`；对应 `configs/classes.json` 里的 id `{our_id}`（写进 classes.json 的 original_id）
- 有目标的帧：{written} / {len(images)}，框 {n_boxes}
- 切分：**按时间顺序**（不是随机）——train {len(splits['train'])} / val {len(splits['val'])}
  随机切分会让验证集混进训练集的近邻帧（走路视频相邻帧几乎一样），指标虚高。

## 局限（必须知道）

1. 标签**继承 COCO 的错误与偏置**：遮挡、背影、伞下的人、欧美场景分布。
   它是**冷启动**，不是最终标注。
2. 拿它评测只能说明「学生学到了老师的多少」，**不等于真实精度**。
   要真实精度必须有**人工核过**的一小批（哪怕 30 帧）。
3. 已剔除无目标帧：没有目标的背景帧对学这一类没有价值。

## 用法

    python scripts/train_yolo.py --data {out.relative_to(REPO_ROOT) if str(out).startswith(str(REPO_ROOT)) else out}/dataset.yaml --classes 1
""", encoding="utf-8")

    print(f"\n写出 {written} 张（有目标），共 {n_boxes} 个框")
    print(f"  train {len(splits['train'])} / val {len(splits['val'])}"
          f"（按时间顺序切）")
    print(f"  输出：{out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

