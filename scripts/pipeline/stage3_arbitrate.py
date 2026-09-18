"""三段式自动预标 —— 第三段：跨类冲突消解 + 汇出最终标签与人工复核清单。

本段不做新的视觉推理。它的职责是把前两段的证据**收敛成三个明确的去处**：

    采纳    -> 写入最终 YOLO 标签
    复核    -> 写入 review.csv，人工只需 Accept/Reject（不用画框）
    丢弃    -> 记入统计，不写标签

为什么要单独一段（而不是塞进第二段）：
    第二段的职责是「对每个候选框取证」。冲突消解需要**同时看到一张图里所有框**，
    属于不同层次的判断。混在一起会让第二段的缓存失效、也无法单独复跑。

冲突消解规则及依据：

1. **跨类重复**：两个类别的框 IoU >= iou_merge 视为同一物体。
   实测背景：垃圾桶被同时检出为 street_obstacle 与 pedestrian（长椅场景下更明显）。
   处置：按「优先级 + 置信度」保留其一。优先级来自 configs/class_aliases.json 的
   `arbitration_priority`（数值小者优先）。

2. **框尺寸异常**：面积占比 > max_area 的框多为「框满全图」的失败输出
   （实测模型偶尔会给出这类框）。标记复核而非直接采纳。

3. **VLM 未判定**（verdict=None）：**标复核，不静默采纳**。
   这是刻意的保守设计——静默采纳会让未验证的框混进数据集，
   而失败是无声的（训练时不报错，只让 mAP 莫名偏低）。

用法：
    python scripts/pipeline/stage3_arbitrate.py \\
        --verified data/auto/trashbin_verified \\
        --images data/raw/route_A/trashbin \\
        --out data/dataset
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
for p in (REPO_ROOT / "scripts", REPO_ROOT / "scripts" / "pipeline"):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from label_taxonomy import LabelTaxonomy, iou_xyxy  # noqa: E402

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def load_jsonl(p: Path) -> list[dict]:
    if not p.exists():
        return []
    out = []
    with p.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def area(bbox: list[float]) -> float:
    return max(0.0, bbox[2] - bbox[0]) * max(0.0, bbox[3] - bbox[1])


def build_priority(tax: LabelTaxonomy) -> dict[int, int]:
    """冲突时哪一类优先保留。数值小者优先，相等则按置信度决胜。

    v1 里靠「伞类垫底」区分优先级（street_obstacle 曾盖着垃圾桶/护柱/雪糕筒）。
    v2 删掉伞类后各类都是具体物件，**不再有系统性优先级差异**，因此默认同级。
    仅保留两类特例：
      - `ambiguous_vertical`（训练专用类）优先级最低——它是「分不清」的兜底，
        不该抢走具体类别的框。
      - `pedestrian` 降一档——它是移动障碍，与静止设施重叠时优先保留设施框，
        因为设施位置稳定、对导航更有用。
    """
    prio: dict[int, int] = {}
    for c in tax.classes:
        explicit = c.get("arbitration_priority")
        if explicit is not None:
            prio[c["id"]] = int(explicit)
        elif c["name_en"] == "ambiguous_vertical":
            prio[c["id"]] = 95
        elif c["name_en"] == "pedestrian":
            prio[c["id"]] = 20
        else:
            prio[c["id"]] = 10
    return prio


def resolve_conflicts(dets: list[dict], prio: dict[int, int],
                      iou_merge: float) -> tuple[list[dict], list[dict]]:
    """跨类重复消解。返回 (保留, 被合并掉的)。"""
    ordered = sorted(dets, key=lambda d: (prio.get(d["class_id"], 50), -d["conf"]))
    kept: list[dict] = []
    merged: list[dict] = []
    for d in ordered:
        dup = None
        for k in kept:
            if k["class_id"] == d["class_id"]:
                continue
            if iou_xyxy(d["bbox"], k["bbox"]) >= iou_merge:
                dup = k
                break
        if dup is None:
            kept.append(d)
        else:
            d = dict(d)
            d["merged_into_class"] = dup["class_id"]
            d["conflict_iou"] = round(iou_xyxy(d["bbox"], dup["bbox"]), 3)
            merged.append(d)
    return kept, merged


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verified", required=True, help="第二段输出目录（含 verified.jsonl）")
    ap.add_argument("--images", required=True, help="原始图像根目录")
    ap.add_argument("--out", default=None,
                    help="最终标签输出目录（默认 <verified>/final）")
    ap.add_argument("--dataset", default=None,
                    help="若指定，则同时写入 YOLO 数据集的 labels/<来源>/<名>.txt 结构")
    ap.add_argument("--iou-merge", type=float, default=0.55,
                    help="跨类重复的 IoU 阈值")
    ap.add_argument("--min-conf", type=float, default=0.20,
                    help="采纳门槛。**必须与第二段的 --min-conf 一致**，否则第二段保住的低置信框"
                         "会在这里被静默丢弃。默认 0.20：过滤应由 VLM 验证承担，而非置信度阈值。")
    ap.add_argument("--max-area", type=float, default=0.75,
                    help="面积占比超过此值的框标记复核（框满全图多为失败输出）")
    ap.add_argument("--min-area", type=float, default=0.0002,
                    help="面积占比低于此值丢弃（过小无意义）")
    ap.add_argument("--review-unknown-verdict", action="store_true", default=True,
                    help="VLM 未判定（None）的框送复核，而非静默采纳")
    ap.add_argument("--single-class", default=None,
                    help="只保留该类别（英文名），并把标签索引重映射为 0，"
                         "同时生成 datasets/<object>.yaml。"
                         "用于「单独训一个物件」的场景——例如垃圾桶不该塞进 16 类"
                         "检测器当 street_obstacle，那会让它与护柱、路障争同一类。")
    ap.add_argument("--dataset-name", default=None,
                    help="--single-class 时生成的数据集名与 yaml 文件名")
    args = ap.parse_args()

    ver_dir = REPO_ROOT / args.verified
    recs = load_jsonl(ver_dir / "verified.jsonl")
    if not recs:
        print(f"未找到 {ver_dir / 'verified.jsonl'}。请先运行 stage2_verify.py。")
        return 1

    img_root = REPO_ROOT / args.images
    tax = LabelTaxonomy()
    prio = build_priority(tax)
    names = {c["id"]: c["name_en"] for c in tax.classes}

    # 单类模式：只保留一个类别，标签索引重映射为 0
    keep_id: int | None = None
    if args.single_class:
        match = [c for c in tax.classes if c["name_en"] == args.single_class]
        if not match:
            print(f"未知类别：{args.single_class}")
            print("可选：" + ", ".join(c["name_en"] for c in tax.classes))
            return 1
        keep_id = match[0]["id"]
        print(f"单类模式：只保留 {args.single_class}（原 id {keep_id} -> 0）")

    out_dir = Path(args.out) if args.out else (ver_dir / "final")
    out_dir = out_dir if out_dir.is_absolute() else (REPO_ROOT / out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    labels_dir = out_dir / "labels"

    stats = Counter()
    review_rows: list[dict] = []
    final_records: list[dict] = []
    class_kept: Counter[int] = Counter()
    img_with_class: Counter[int] = Counter()

    for rec in recs:
        src = Path(rec["source"])
        if not src.exists():
            src = REPO_ROOT / rec["source"]
        rel = rec["image"]
        dets_in = rec.get("detections", [])

        # --- 0. 单类模式：先滤掉非目标类别 ---
        if keep_id is not None:
            n_before = len(dets_in)
            dets_in = [d for d in dets_in if d["class_id"] == keep_id]
            stats["drop_other_class"] += n_before - len(dets_in)

        # --- 1. 置信度与尺寸门槛 ---
        stage_a: list[dict] = []
        for d in dets_in:
            a = area(d["bbox"])
            if d["conf"] < args.min_conf:
                stats["drop_low_conf"] += 1
                continue
            if a < args.min_area:
                stats["drop_tiny"] += 1
                continue
            if a > args.max_area:
                stats["review_huge"] += 1
                review_rows.append({
                    "image": rel, "class": names.get(d["class_id"], d["class_id"]),
                    "bbox": d["bbox"], "conf": round(d["conf"], 3), "area": round(a, 4),
                    "reason": "框面积异常大（疑似框满全图）", "vlm_verdict": d.get("vlm_verdict"),
                })
                continue
            stage_a.append(d)

        # --- 2. VLM 未判定的送复核 ---
        stage_b: list[dict] = []
        for d in stage_a:
            if args.review_unknown_verdict and d.get("vlm_verified") and d.get("vlm_verdict") is None:
                stats["review_unknown_verdict"] += 1
                review_rows.append({
                    "image": rel, "class": names.get(d["class_id"], d["class_id"]),
                    "bbox": d["bbox"], "conf": round(d["conf"], 3),
                    "area": round(area(d["bbox"]), 4),
                    "reason": "VLM 未能判定（输出无该类别或无法解析）",
                    "vlm_verdict": None,
                })
                continue
            stage_b.append(d)

        # --- 3. 跨类冲突消解 ---
        kept, merged_away = resolve_conflicts(stage_b, prio, args.iou_merge)
        stats["merged_cross_class"] += len(merged_away)
        for d in merged_away[:50]:
            review_rows.append({
                "image": rel, "class": names.get(d["class_id"], d["class_id"]),
                "bbox": d["bbox"], "conf": round(d["conf"], 3),
                "area": round(area(d["bbox"]), 4),
                "reason": f"与 {names.get(d['merged_into_class'], '?')} 重叠 "
                          f"(IoU {d.get('conflict_iou')})，已按优先级合并",
                "vlm_verdict": d.get("vlm_verdict"),
            })

        stats["accepted"] += len(kept)
        for d in kept:
            class_kept[d["class_id"]] += 1
        for cid in {d["class_id"] for d in kept}:
            img_with_class[cid] += 1

        final_records.append({**rec, "detections": kept})

        # --- 写标签 ---
        lp = labels_dir / (Path(rel).with_suffix("").as_posix().replace("/", "__") + ".txt")
        lp.parent.mkdir(parents=True, exist_ok=True)
        lines = []
        for d in sorted(kept, key=lambda x: x["class_id"]):
            x1, y1, x2, y2 = d["bbox"]
            # 单类模式下所有框索引归 0
            out_id = 0 if keep_id is not None else d["class_id"]
            lines.append(f"{out_id} {(x1+x2)/2:.6f} {(y1+y2)/2:.6f} "
                         f"{x2-x1:.6f} {y2-y1:.6f}")
        # 空标签也要写：空文件 = 有效负样本，与「缺文件」语义不同
        lp.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")

    (out_dir / "final.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in final_records) + "\n",
        encoding="utf-8")

    # --- 复核清单 ---
    review_csv = out_dir / "review.csv"
    with review_csv.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["image", "class", "bbox", "conf", "area",
                                          "reason", "vlm_verdict"])
        w.writeheader()
        w.writerows(review_rows)

    # --- 可选：直接写入 YOLO 数据集结构 ---
    dataset_info = None
    if args.dataset:
        ds = Path(args.dataset)
        ds = ds if ds.is_absolute() else (REPO_ROOT / ds)
        images_out = ds / "images"
        labels_out = ds / "labels"
        n_copied = 0
        import shutil
        for rec in final_records:
            src = Path(rec["source"])
            if not src.exists():
                src = REPO_ROOT / rec["source"]
            if not src.exists():
                continue
            try:
                rel_to_root = src.relative_to(img_root)
            except ValueError:
                rel_to_root = Path(src.name)
            # 来源文件夹 = 分组划分的依据，必须保留
            source_folder = rel_to_root.parent.as_posix() if str(rel_to_root.parent) != "." else src.parent.name
            (images_out / source_folder).mkdir(parents=True, exist_ok=True)
            (labels_out / source_folder).mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, images_out / source_folder / src.name)
            lbl_src = labels_dir / (Path(rec["image"]).with_suffix("").as_posix().replace("/", "__") + ".txt")
            if lbl_src.exists():
                shutil.copy2(lbl_src, labels_out / source_folder / f"{src.stem}.txt")
            n_copied += 1
        dataset_info = {"images_copied": n_copied, "root": str(ds.relative_to(REPO_ROOT))}

    # --- 单类模式：生成配套数据集 yaml ---
    yaml_info = None
    if keep_id is not None and args.dataset:
        ds_name = args.dataset_name or args.single_class
        train_list = out_dir / "train.txt"
        paths = []
        for rec in final_records:
            src = Path(rec["source"])
            if not src.exists():
                src = REPO_ROOT / rec["source"]
            try:
                rel = src.relative_to(img_root)
            except ValueError:
                rel = Path(src.name)
            folder = rel.parent.as_posix() if str(rel.parent) != "." else src.parent.name
            paths.append(str((Path(args.dataset) if Path(args.dataset).is_absolute()
                              else REPO_ROOT / args.dataset) / "images" / folder / src.name))
        train_list.write_text("\n".join(paths) + ("\n" if paths else ""), encoding="utf-8")

        yaml_dir = REPO_ROOT / "datasets"
        yaml_dir.mkdir(parents=True, exist_ok=True)
        yaml_path = yaml_dir / f"{ds_name}.yaml"
        ds_root = Path(args.dataset) if Path(args.dataset).is_absolute() else (REPO_ROOT / args.dataset)
        yaml_path.write_text(
            f"# 由 scripts/pipeline/stage3_arbitrate.py --single-class 自动生成\n"
            f"# 单物件数据集：{args.single_class}\n"
            f"path: {ds_root.as_posix()}\n"
            f"train: {train_list.as_posix()}\n"
            f"val: {train_list.as_posix()}\n\n"
            f"nc: 1\n"
            f"names:\n  0: {args.single_class}\n",
            encoding="utf-8")
        yaml_info = {"yaml": str(yaml_path.relative_to(REPO_ROOT)), "nc": 1,
                     "name": args.single_class, "train_list": str(train_list.relative_to(REPO_ROOT))}
        print(f"单类数据集配置 -> {yaml_path.relative_to(REPO_ROOT)}")
        print("  注意：val 暂指向同一清单，仅供跑通；正式训练前请用 split_dataset.py 划分")

    report = {
        "images": len(recs),
        "input_boxes": sum(len(r.get("detections", [])) for r in recs),
        "accepted": stats["accepted"],
        "review_items": len(review_rows),
        "drop_low_conf": stats["drop_low_conf"],
        "drop_tiny": stats["drop_tiny"],
        "drop_other_class": stats["drop_other_class"],
        "single_class": args.single_class,
        "dataset_yaml": yaml_info,
        "review_huge": stats["review_huge"],
        "review_unknown_verdict": stats["review_unknown_verdict"],
        "merged_cross_class": stats["merged_cross_class"],
        "per_class": {
            str(c["id"]): {"name_en": c["name_en"], "name_zh": c["name_zh"],
                           "boxes": class_kept.get(c["id"], 0),
                           "images": img_with_class.get(c["id"], 0)}
            for c in tax.classes
        },
        "dataset": dataset_info,
    }
    (out_dir / "stage3_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    # --- 终端输出 ---
    print(f"输入 {report['images']} 张，候选框 {report['input_boxes']}")
    print(f"采纳 {report['accepted']}   需复核 {report['review_items']}   "
          f"丢弃 {report['drop_low_conf'] + report['drop_tiny']}")
    print(f"\n处置明细：")
    for k, label in (("drop_low_conf", "  置信度不足丢弃"),
                     ("drop_tiny", "  面积过小丢弃"),
                     ("review_huge", "  面积异常大 -> 复核"),
                     ("review_unknown_verdict", "  VLM 未判定 -> 复核"),
                     ("merged_cross_class", "  跨类重复合并")):
        if stats[k]:
            print(f"{label:<24} {stats[k]}")
    print(f"\n{'id':>3} {'类别':<24} {'框数':>6} {'出现图':>7}")
    for cid in sorted(class_kept):
        print(f"{cid:>3} {names[cid]:<24} {class_kept[cid]:>6} {img_with_class[cid]:>7}")
    zero = [names[c["id"]] for c in tax.classes if not class_kept.get(c["id"])]
    if zero:
        print(f"\n零框类别（{len(zero)}）：{', '.join(zero)}")
    print(f"\n最终标签 -> {labels_dir.relative_to(REPO_ROOT)}")
    print(f"复核清单 -> {review_csv.relative_to(REPO_ROOT)}")
    if dataset_info:
        print(f"数据集   -> {dataset_info['root']}  ({dataset_info['images_copied']} 张)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
