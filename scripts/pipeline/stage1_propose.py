"""三段式自动预标 —— 第一段：YOLO-World 极速出框。

对每张图用**全部类别的全部 prompt 说法**推理，再做**类内 NMS 合并**。
这样既拿到「多说法」带来的高召回，又保持 prompt -> 类别 id 的确定性映射
（若对每个类别单独跑一次，虽然结论更干净，但 N 个类别要跑 N 遍，慢 N 倍）。

产出：
    <out>/proposals.jsonl   每张图的候选框（类别 id、归一化框、置信度、命中的 prompt）
    <out>/proposals_stats.json  逐类框数统计

用法：
    python scripts/pipeline/stage1_propose.py --images data/probe/hk --out data/auto/proposals
    python scripts/pipeline/stage1_propose.py --images data/raw/route_A --out data/auto/proposals \
        --weights yolov8m-world.pt --limit 50
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(REPO_ROOT / "scripts" / "pipeline"))

import env_setup  # noqa: E402  必须在 ultralytics 之前导入

from label_taxonomy import LabelTaxonomy, normalize_text  # noqa: E402

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def find_images(root: Path, recursive: bool = True) -> list[Path]:
    it = root.rglob("*") if recursive else root.glob("*")
    return sorted(p for p in it if p.is_file() and p.suffix.lower() in IMAGE_EXTS)


def yolo_to_xyxy(box: list[float], w: int, h: int) -> tuple[float, float, float, float]:
    """Ultralytics 的 xywh（像素、中心点）-> 归一化 xyxy。"""
    cx, cy, bw, bh = box
    return ((cx - bw / 2) / w, (cy - bh / 2) / h, (cx + bw / 2) / w, (cy + bh / 2) / h)


def nms_same_class(dets: list[dict], iou_thr: float) -> list[dict]:
    """类内 NMS：同一类别、重叠高的框只留置信度最高的。

    为什么需要：同一类别的多个 prompt 说法（"stairs" / "staircase" / "steps"）
    会各出一批框、彼此高度重叠。不合并会导致后续跨模型匹配时
    一个真实目标对应多个候选，IoU 比较失去意义。
    """
    def iou(a: dict, b: dict) -> float:
        ax1, ay1, ax2, ay2 = a["bbox"]
        bx1, by1, bx2, by2 = b["bbox"]
        ix1, iy1 = max(ax1, bx1), max(ay1, by1)
        ix2, iy2 = min(ax2, bx2), min(ay2, by2)
        iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
        inter = iw * ih
        if inter <= 0:
            return 0.0
        aa = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
        ab = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
        u = aa + ab - inter
        return inter / u if u > 0 else 0.0

    ordered = sorted(dets, key=lambda d: d["conf"], reverse=True)
    kept: list[dict] = []
    for d in ordered:
        if all(iou(d, k) <= iou_thr for k in kept):
            kept.append(d)
    return kept


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True, help="输入图像目录（递归）")
    ap.add_argument("--out", default="data/auto/proposals")
    ap.add_argument("--weights", default="yolov8s-world.pt",
                    help="yolov8s-world.pt（快）/ yolov8m-world.pt（更准）")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=0.15,
                    help="预标阶段门槛要低：宁可多留候选，由后两段筛掉")
    ap.add_argument("--iou-merge", type=float, default=0.55,
                    help="类内合并的 IoU 阈值")
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--limit", type=int, default=None, help="只处理前 N 张（试跑用）")
    ap.add_argument("--no-labels", action="store_true",
                    help="只写 proposals.jsonl，不写 YOLO 标签文件")
    args = ap.parse_args()

    images_root = (REPO_ROOT / args.images) if not Path(args.images).is_absolute() else Path(args.images)
    if not images_root.exists():
        print(f"输入目录不存在：{images_root}")
        return 1
    images = find_images(images_root)
    if args.limit:
        images = images[: args.limit]
    if not images:
        print(f"未在 {images_root} 找到图像。")
        return 1

    out_dir = REPO_ROOT / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    tax = LabelTaxonomy()
    prompts = tax.yolo_world_prompts()
    prompt_to_id = tax.prompt_to_id()
    print(f"图像 {len(images)} 张 -> {images_root.relative_to(REPO_ROOT)}")
    print(f"类别 {len(tax.classes)} 个，prompt 说法 {len(prompts)} 条")

    from ultralytics import YOLO

    model = YOLO(args.weights)
    model.set_classes(prompts)
    # Ultraalytics 会把 set_classes 的文本按原顺序存为 names
    names = model.names
    if len(names) != len(prompts):
        print(f"[WARN] names 数 ({len(names)}) 与 prompts 数 ({len(prompts)}) 不一致，按索引对齐")
    idx_to_id = {}
    for i, p in enumerate(prompts):
        cid = prompt_to_id.get(normalize_text(p))
        if cid is not None:
            idx_to_id[i] = cid

    t0 = time.time()
    n_images = 0
    n_boxes_raw = 0
    n_boxes_kept = 0
    class_hits: Counter[int] = Counter()
    img_with_class: dict[int, set[str]] = {}

    jsonl_path = out_dir / "proposals.jsonl"
    labels_dir = out_dir / "labels"
    if not args.no_labels:
        labels_dir.mkdir(parents=True, exist_ok=True)

    with jsonl_path.open("w", encoding="utf-8") as jf:
        for start in range(0, len(images), args.batch):
            chunk = images[start:start + args.batch]
            results = model.predict([str(p) for p in chunk], imgsz=args.imgsz,
                                    conf=args.conf, verbose=False)
            for path, r in zip(chunk, results):
                h, w = r.orig_shape[:2]
                raw: list[dict] = []
                if r.boxes is not None and len(r.boxes):
                    cls = r.boxes.cls.tolist()
                    conf = r.boxes.conf.tolist()
                    xywh = r.boxes.xywh.tolist()
                    for c_i, cf, box in zip(cls, conf, xywh):
                        cid = idx_to_id.get(int(c_i))
                        if cid is None:
                            continue
                        raw.append({"class_id": cid, "conf": float(cf),
                                    "bbox": yolo_to_xyxy(box, w, h),
                                    "prompt": prompts[int(c_i)]})
                n_boxes_raw += len(raw)

                # 类内合并
                by_class: dict[int, list[dict]] = {}
                for d in raw:
                    by_class.setdefault(d["class_id"], []).append(d)
                merged: list[dict] = []
                for cid, dets in by_class.items():
                    for d in nms_same_class(dets, args.iou_merge):
                        d["n_prompts"] = sum(
                            1 for x in dets if x["conf"] >= args.conf)
                        merged.append(d)
                merged.sort(key=lambda d: d["conf"], reverse=True)
                n_boxes_kept += len(merged)
                for d in merged:
                    class_hits[d["class_id"]] += 1
                    img_with_class.setdefault(d["class_id"], set()).add(str(path))

                rel = path.relative_to(images_root).as_posix()
                jf.write(json.dumps({
                    "image": rel, "source": str(path), "width": w, "height": h,
                    "detections": merged,
                }, ensure_ascii=False) + "\n")

                if not args.no_labels:
                    lines = []
                    for d in merged:
                        x1, y1, x2, y2 = d["bbox"]
                        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
                        bw, bh = x2 - x1, y2 - y1
                        lines.append(f"{d['class_id']} {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}")
                    lp = labels_dir / (Path(rel).with_suffix("").as_posix().replace("/", "__") + ".txt")
                    lp.parent.mkdir(parents=True, exist_ok=True)
                    # 空标签也要写：空文件是有效的负样本，与"缺文件"语义不同
                    lp.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
                n_images += 1

            done = min(start + args.batch, len(images))
            if done % 80 == 0 or done == len(images):
                rate = done / max(time.time() - t0, 1e-9)
                print(f"  {done}/{len(images)}  ({rate:.1f} img/s)", flush=True)

    elapsed = time.time() - t0
    stats = {
        "images": n_images,
        "boxes_raw": n_boxes_raw,
        "boxes_after_merge": n_boxes_kept,
        "elapsed_s": round(elapsed, 1),
        "img_per_s": round(n_images / elapsed, 2) if elapsed else None,
        "weights": args.weights,
        "imgsz": args.imgsz,
        "conf": args.conf,
        "iou_merge": args.iou_merge,
        "per_class": {
            str(c["id"]): {
                "name_en": c["name_en"], "name_zh": c["name_zh"],
                "boxes": class_hits.get(c["id"], 0),
                "images": len(img_with_class.get(c["id"], ())),
            }
            for c in tax.classes
        },
    }
    (out_dir / "proposals_stats.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n完成：{n_images} 张，{elapsed:.1f}s（{stats['img_per_s']} img/s）")
    print(f"框：原始 {n_boxes_raw} -> 类内合并后 {n_boxes_kept}")
    print(f"\n{'id':>3} {'类别':<24} {'框数':>7} {'出现图数':>8}")
    for cid in sorted(int(k) for k in stats["per_class"]):
        e = stats["per_class"][str(cid)]
        if e["boxes"]:
            print(f"{cid:>3} {e['name_en']:<24} {e['boxes']:>7} {e['images']:>8}")
    zero = [stats["per_class"][str(c["id"])]["name_en"] for c in tax.classes
            if not stats["per_class"][str(c["id"])]["boxes"]]
    if zero:
        print(f"\n零框类别（{len(zero)}）：{', '.join(zero)}")
    print(f"\n候选框：{jsonl_path.relative_to(REPO_ROOT)}")
    print(f"统计  ：{(out_dir / 'proposals_stats.json').relative_to(REPO_ROOT)}")
    if not args.no_labels:
        print(f"标签  ：{labels_dir.relative_to(REPO_ROOT)}  （第一段草稿，未经复核）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
