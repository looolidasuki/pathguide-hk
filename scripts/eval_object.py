"""单物件训练效果评估。

回答的问题：**「我这批图，这个物件到底训得怎么样？」**

分三层，从便宜到贵：
    第 1 层  自动标注质量（本脚本，秒级）—— 出框率、复核通过率、修框质量
    第 2 层  视觉核对（本脚本生成叠加图）—— 肉眼看框准不准，**最有信息量**
    第 3 层  真实训练指标（需标注真值）—— mAP / 每类召回率

用法：
    python scripts/eval_object.py --name trashbin \\
        --raw data/raw/route_A/trashbin \\
        --proposals data/auto/trashbin \\
        --verified data/auto/trashbin_verified \\
        --class street_obstacle --overlay

    # 只出叠加图、不做统计
    python scripts/eval_object.py --name trashbin --verified data/auto/trashbin_verified \\
        --class street_obstacle --overlay-only
"""
from __future__ import annotations

import argparse
import json
import statistics
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
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


def find_images(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*")
                  if p.is_file() and p.suffix.lower() in IMAGE_EXTS)


def draw_overlay(img_path: Path, dets: list[dict], names: dict[int, str],
                 out_path: Path, src_dets: list[dict] | None = None) -> None:
    """画叠加图：绿框=采纳（最终标签），红框=被丢弃的候选。

    这是本脚本最有价值的部分——数字只能告诉你"多少个框"，
    叠加图能告诉你"框得准不准、漏了什么、误检长什么样"。
    """
    from PIL import Image, ImageDraw

    img = Image.open(img_path).convert("RGB")
    W, H = img.size
    d = ImageDraw.Draw(img)

    if src_dets:
        for det in src_dets:
            x1, y1, x2, y2 = det["bbox"]
            d.rectangle([x1 * W, y1 * H, x2 * W, y2 * H], outline=(220, 40, 40), width=2)

    for det in dets:
        x1, y1, x2, y2 = det["bbox"]
        px = [x1 * W, y1 * H, x2 * W, y2 * H]
        # 经 VLM 验证的用亮绿，未验证的用黄
        color = (0, 210, 90) if det.get("vlm_verified") else (240, 200, 0)
        d.rectangle(px, outline=color, width=3)
        label = names.get(det["class_id"], str(det["class_id"]))
        conf = det.get("conf", 0)
        tag = f"{label} {conf:.2f}"
        if det.get("refined"):
            tag += " [SAM]"
        ty = max(0, px[1] - 13)
        d.rectangle([px[0], ty, px[0] + 8 * len(tag), ty + 12], fill=color)
        d.text((px[0] + 2, ty + 1), tag, fill=(0, 0, 0))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, quality=88)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, help="物件名（仅用于报告标题与输出目录）")
    ap.add_argument("--raw", default=None, help="原始图像目录（用于统计总数与出叠加图）")
    ap.add_argument("--proposals", default=None, help="第一段 proposals.jsonl 所在目录")
    ap.add_argument("--verified", default=None, help="第二段 verified.jsonl 所在目录")
    ap.add_argument("--class", dest="class_name", default=None,
                    help="关注哪个类别（英文名，如 street_obstacle）")
    ap.add_argument("--overlay", action="store_true", help="生成叠加图")
    ap.add_argument("--overlay-only", action="store_true", help="只生成叠加图")
    ap.add_argument("--overlay-limit", type=int, default=None, help="最多生成多少张叠加图")
    ap.add_argument("--out", default=None, help="输出目录，默认 data/eval/<name>")
    args = ap.parse_args()

    with CLASSES_PATH.open(encoding="utf-8") as f:
        classes = sorted(json.load(f)["classes"], key=lambda c: c["id"])
    names = {c["id"]: c["name_en"] for c in classes}
    zh = {c["id"]: c["name_zh"] for c in classes}
    name_to_id = {c["name_en"]: c["id"] for c in classes}
    target_id = name_to_id.get(args.class_name) if args.class_name else None

    out_dir = REPO_ROOT / (args.out or f"data/eval/{args.name}")
    out_dir.mkdir(parents=True, exist_ok=True)

    s1 = load_jsonl(REPO_ROOT / args.proposals / "proposals.jsonl") if args.proposals else []
    s2 = load_jsonl(REPO_ROOT / args.verified / "verified.jsonl") if args.verified else []

    src_by_img = {r["image"]: r for r in s1}
    ver_by_img = {r["image"]: r for r in s2}

    n_total = None
    if args.raw:
        raw_root = REPO_ROOT / args.raw
        imgs = find_images(raw_root)
        n_total = len(imgs)
    elif s1:
        n_total = len(s1)
    elif s2:
        n_total = len(s2)

    lines: list[str] = [f"# 物件「{args.name}」自动标注效果评估", ""]
    print(f"# 物件「{args.name}」自动标注效果评估\n")

    if n_total is not None:
        lines.append(f"- 图像总数：{n_total}")
        print(f"图像总数：{n_total}")

    # ---- 逐类别统计 ----
    def summarize(recs: list[dict], label: str) -> tuple[Counter, Counter]:
        boxes: Counter[int] = Counter()
        imgs: Counter[int] = Counter()
        for r in recs:
            dets = r.get("detections", [])
            for d in dets:
                boxes[d["class_id"]] += 1
            for cid in {d["class_id"] for d in dets}:
                imgs[cid] += 1
        return boxes, imgs

    if s1 and not args.overlay_only:
        b1, i1 = summarize(s1, "第一段")
        lines += ["", "## 第一段 · YOLO-World 原始出框", "",
                  "| 类别 | 框数 | 出现图数 | 出框率 |", "|---|---|---|---|"]
        print("\n【第一段】YOLO-World 原始出框")
        print(f"{'类别':<24} {'框数':>6} {'出现图':>7} {'出框率':>8}")
        for cid, n in b1.most_common():
            rate = i1[cid] / n_total if n_total else 0
            lines.append(f"| {names[cid]} | {n} | {i1[cid]} | {rate:.0%} |")
            print(f"{names[cid]:<24} {n:>6} {i1[cid]:>7} {rate:>8.0%}")

    if s2 and not args.overlay_only:
        b2, i2 = summarize(s2, "第二段")
        lines += ["", "## 第二段 · SAM 修框 + VLM 复核后", "",
                  "| 类别 | 框数 | 出现图数 | 保留率 |", "|---|---|---|---|"]
        print("\n【第二段】SAM 修框 + VLM 复核后")
        print(f"{'类别':<24} {'框数':>6} {'出现图':>7} {'保留率':>8}")
        b1 = summarize(s1, "")[0] if s1 else Counter()
        for cid, n in b2.most_common():
            keep = n / b1[cid] if b1.get(cid) else 0
            lines.append(f"| {names[cid]} | {n} | {i2[cid]} | {keep:.0%} |")
            print(f"{names[cid]:<24} {n:>6} {i2[cid]:>7} {keep:>8.0%}")

        all_dets = [d for r in s2 for d in r["detections"]]
        ver = [d for d in all_dets if d.get("vlm_verified")]
        ref = [d for d in all_dets if d.get("refined")]
        ious = [d["refine_iou"] for d in all_dets if d.get("refine_iou") is not None]
        confs = [d["conf"] for d in all_dets]
        lines += ["", "## 质量指标", "",
                  f"- 采纳框：{len(all_dets)}",
                  f"- 经 VLM 验证：{len(ver)}（{len(ver)/max(len(all_dets),1):.0%}）",
                  f"- 经 SAM 修框：{len(ref)}（{len(ref)/max(len(all_dets),1):.0%}）"]
        print(f"\n【质量】采纳 {len(all_dets)} 框，"
              f"VLM 验证 {len(ver)}，SAM 修框 {len(ref)}")
        if ious:
            lines.append(f"- 修框 IoU：中位 {statistics.median(ious):.3f}"
                         f"（{min(ious):.3f} ~ {max(ious):.3f}）")
            print(f"  修框 IoU 中位 {statistics.median(ious):.3f}")
        if confs:
            lines.append(f"- 置信度：中位 {statistics.median(confs):.3f}"
                         f"（{min(confs):.3f} ~ {max(confs):.3f}）")
            print(f"  置信度中位 {statistics.median(confs):.3f}")

    # ---- 关注类别的专项结论 ----
    if target_id is not None and s1 and s2 and not args.overlay_only:
        b1c = Counter(d["class_id"] for r in s1 for d in r["detections"])
        b2c = Counter(d["class_id"] for r in s2 for d in r["detections"])
        i1c = Counter()
        i2c = Counter()
        for r in s1:
            for cid in {d["class_id"] for d in r["detections"]}:
                i1c[cid] += 1
        for r in s2:
            for cid in {d["class_id"] for d in r["detections"]}:
                i2c[cid] += 1
        tz = zh.get(target_id, "")
        lines += ["", f"## 关注物件：{names[target_id]}（{tz}）", "",
                  f"- 第一段检出：{i1c.get(target_id,0)}/{n_total} = "
                  f"{i1c.get(target_id,0)/n_total:.0%} 的图里找到",
                  f"- 第二段保留：{i2c.get(target_id,0)}/{n_total} = "
                  f"{i2c.get(target_id,0)/n_total:.0%} 的图里保留",
                  f"- 复核通过率：{b2c.get(target_id,0)/max(b1c.get(target_id,1),1):.0%}"]
        print(f"\n【关注物件 {names[target_id]}（{tz}）】")
        print(f"  第一段检出 {i1c.get(target_id,0)}/{n_total} = {i1c.get(target_id,0)/n_total:.0%}")
        print(f"  第二段保留 {i2c.get(target_id,0)}/{n_total} = {i2c.get(target_id,0)/n_total:.0%}")

    # ---- 叠加图 ----
    if args.overlay or args.overlay_only:
        if not args.raw:
            print("\n[提示] 生成叠加图需要 --raw 指定原始图像目录。")
        else:
            raw_root = REPO_ROOT / args.raw
            ov_dir = out_dir / "overlay"
            n_made = 0
            for img in find_images(raw_root):
                rel_candidates = [img.relative_to(raw_root).as_posix(), img.name]
                rec = None
                for key in rel_candidates:
                    if key in ver_by_img:
                        rec = ver_by_img[key]
                        break
                if rec is None:
                    for k, v in ver_by_img.items():
                        if Path(k).name == img.name:
                            rec = v
                            break
                if rec is None and target_id is not None:
                    continue
                src = None
                for k, v in src_by_img.items():
                    if Path(k).name == img.name:
                        src = v
                        break
                draw_overlay(img, rec.get("detections", []) if rec else [],
                             names, ov_dir / f"{img.stem}_annotated.jpg",
                             src_dets=src.get("detections", []) if src else None)
                n_made += 1
                if args.overlay_limit and n_made >= args.overlay_limit:
                    break
            print(f"\n叠加图 {n_made} 张 -> {ov_dir.relative_to(REPO_ROOT)}")
            print("  绿色=采纳框（经VLM验证）  黄色=采纳但未验证  红色=被丢弃的候选")
            lines += ["", f"## 叠加图（{n_made} 张）", "",
                      f"目录：`{ov_dir.relative_to(REPO_ROOT).as_posix()}`", "",
                      "- 绿框：采纳，且经 VLM 验证",
                      "- 黄框：采纳，但未经验证",
                      "- 红框：被丢弃的候选（可用于发现漏检与误检）"]

    (out_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"\n报告 -> {(out_dir / 'report.md').relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
