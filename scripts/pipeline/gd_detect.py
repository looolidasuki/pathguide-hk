"""类别发现 + Grounding DINO 检测（单 prompt 模式）。

回答两个问题：
  1. 画面里有哪些**我们类别表内**的物件？（candidates.csv）
  2. 画面里有哪些**我们类别表外**的物件？（out_of_taxonomy.csv）★

第 2 个是论文 *Label Anything, Train Nothing* 的核心机制：**先发现有什么，再决定标什么**。
没有它，表外物件会**静默漏掉**——不报错、不提示，只是不存在。

**为什么每次只发一个 prompt**（实测教训）：
  每组发 6 个 prompt 时，Grounding DINO 产生 `##cala stairs`、`estor` 等破损标签，
  且 `estor` 被错误映射成 `shop_front`。单 prompt 后异常降至 12/792。
  破损标签的危害是**静默污染数据集**——训练时不报错，只让 mAP 莫名偏低。

用法：
    .venv-vlm\\Scripts\\python.exe scripts\\pipeline\\gd_detect.py \\
        --images data/probe/streetview --out data/discover/streetview
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
for p in (REPO_ROOT / "scripts", REPO_ROOT / "scripts" / "pipeline"):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from label_taxonomy import LabelTaxonomy  # noqa: E402

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
DEFAULT_MODEL = "IDEA-Research/grounding-dino-tiny"


def find_images(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*")
                  if p.is_file() and p.suffix.lower() in IMAGE_EXTS)


def load_taxonomy_and_prompts() -> tuple[LabelTaxonomy, list[dict], list[str]]:
    """返回 (taxonomy, 类别表内待查词, 表外候选词)。"""
    tax = LabelTaxonomy()
    in_tax: list[dict] = []
    for c in tax.classes:
        if c.get("never_from_vlm"):
            continue
        # Grounding DINO 的 prompt 用 gdin_prompt（若有），否则用 verify_query
        q = c.get("gdin_prompt") or c.get("verify_query")
        if not q:
            continue
        in_tax.append({"class_id": c["id"], "name_en": c["name_en"],
                       "query": str(q).lower(),
                       "threshold": float(c.get("gdin_threshold") or 0.30)})
    with (REPO_ROOT / "configs" / "class_aliases.json").open(encoding="utf-8") as f:
        doc = json.load(f)
    oot = doc["out_of_taxonomy_candidates"]
    out_words = [w.lower() for w in oot["words"]]
    return tax, in_tax, out_words


def draw(img, dets: list[dict], out_path: Path) -> None:
    from PIL import ImageDraw

    d = ImageDraw.Draw(img)
    W, H = img.size
    for det in dets:
        x1, y1, x2, y2 = det["bbox"]
        px = [x1 * W, y1 * H, x2 * W, y2 * H]
        in_tax = det.get("class_id") is not None
        color = (0, 220, 80) if in_tax else (255, 150, 0)   # 绿=表内, 橙=表外
        d.rectangle(px, outline=color, width=3)
        tag = f"{det['label'][:16]} {det['conf']:.2f}"
        ty = max(0, px[1] - 13)
        d.rectangle([px[0], ty, px[0] + 7 * len(tag), ty + 12], fill=color)
        d.text((px[0] + 2, ty + 1), tag, fill=(0, 0, 0) if in_tax else (255, 255, 255))
    img.save(out_path, quality=90)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True)
    ap.add_argument("--out", default=None, help="默认 data/discover/<图片目录名>")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--model-path", default=None,
                    help="本地模型快照目录。**建议指定**——本项目 HF 缓存分居两地"
                         "（LocateAnything 在 ~/.cache，Grounding DINO 在工作区内 .hf/hub），"
                         "而 HF_HUB_CACHE 只能指一处，指错会触发重新下载或权限错误。"
                         "直接给快照目录可绕开缓存解析。")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--overlay", action="store_true", default=True)
    ap.add_argument("--no-overlay", dest="overlay", action="store_false")
    ap.add_argument("--overlay-limit", type=int, default=None)
    ap.add_argument("--oot-threshold", type=float, default=0.35,
                    help="表外候选词的置信度门槛。实测 lamb post/tree/sign 在低阈值下出框率 100%%，"
                         "明显是误检，故表外词用比表内更高的门槛。")
    args = ap.parse_args()

    img_root = Path(args.images)
    img_root = img_root if img_root.is_absolute() else (REPO_ROOT / img_root)
    if not img_root.exists():
        print(f"输入目录不存在：{img_root}")
        return 1
    images = find_images(img_root)
    if args.limit:
        images = images[: args.limit]
    if not images:
        print(f"未在 {img_root} 找到图像。")
        return 1

    out_dir = Path(args.out) if args.out else (REPO_ROOT / "data" / "discover" / img_root.name)
    out_dir = out_dir if out_dir.is_absolute() else (REPO_ROOT / out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    tax, in_tax, oot_words = load_taxonomy_and_prompts()
    all_queries = [(d["query"], d["class_id"], d["threshold"], d["name_en"]) for d in in_tax]
    all_queries += [(w, None, args.oot_threshold, w) for w in oot_words]

    print(f"图像      : {len(images)} 张")
    print(f"类别表内  : {len(in_tax)} 个待查词")
    print(f"表外候选  : {len(oot_words)} 个词")
    print(f"每图推理  : {len(all_queries)} 次（**每次单 prompt**）")
    print(f"模型      : {args.model}")

    import torch
    from PIL import Image
    from transformers import AutoProcessor, AutoModelForZeroShotObjectDetection

    t0 = time.time()
    src = args.model_path or args.model
    proc = AutoProcessor.from_pretrained(src, local_files_only=bool(args.model_path))
    model = AutoModelForZeroShotObjectDetection.from_pretrained(
        src, local_files_only=bool(args.model_path)).to("cuda").eval()
    print(f"模型就绪 {time.time() - t0:.1f}s  ({src})\n", flush=True)

    def infer(img, query: str, thr: float):
        inp = proc(images=img, text=query + ".", return_tensors="pt").to("cuda")
        with torch.no_grad():
            out = model(**inp)
        res = proc.post_process_grounded_object_detection(
            out, inp.input_ids, threshold=thr, text_threshold=0.2,
            target_sizes=[img.size[::-1]])[0]
        W, H = img.size
        hits = []
        labels = res.get("text_labels") or res.get("labels") or []
        for b, s, l in zip(res["boxes"].tolist(), res["scores"].tolist(), labels):
            hits.append({
                "bbox": [b[0] / W, b[1] / H, b[2] / W, b[3] / H],
                "conf": float(s), "label": str(l).strip(),
            })
        return hits

    # 预热
    infer(Image.open(images[0]).convert("RGB"), all_queries[0][0], all_queries[0][2])

    in_rows: list[dict] = []
    oot_rows: list[dict] = []
    oot_count: Counter[str] = Counter()
    oot_images: dict[str, set] = defaultdict(set)
    oot_samples: dict[str, str] = {}
    mismatch: Counter[str] = Counter()      # 返回标签 != 所问 query
    ov_dir = out_dir / "overlay"
    if args.overlay:
        ov_dir.mkdir(parents=True, exist_ok=True)

    t1 = time.time()
    for i, p in enumerate(images, 1):
        img = Image.open(p).convert("RGB")
        img_dets: list[dict] = []
        for query, cid, thr, name in all_queries:
            for h in infer(img, query, thr):
                # 标签异常检测：返回的 label 与所问 query 不一致时计入（可能是 tokenizer 破损）
                ret = h["label"].lower().strip()
                if ret != query and ret not in (query, query.replace(" ", "")):
                    mismatch[ret] += 1
                row = {"image": p.name, "query": query, "label": h["label"],
                       "conf": round(h["conf"], 4), "bbox": [round(v, 4) for v in h["bbox"]]}
                if cid is None:
                    row["class_id"] = None
                    oot_rows.append(row)
                    oot_count[h["label"]] += 1
                    oot_images[h["label"]].add(p.name)
                    oot_samples.setdefault(h["label"], p.name)
                    img_dets.append({"bbox": h["bbox"], "conf": h["conf"],
                                     "label": h["label"], "class_id": None})
                else:
                    row["class_id"] = cid
                    in_rows.append(row)
                    img_dets.append({"bbox": h["bbox"], "conf": h["conf"],
                                     "label": h["label"], "class_id": cid})
        if args.overlay and (args.overlay_limit is None or i <= args.overlay_limit):
            draw(img, img_dets, ov_dir / f"{p.stem}_discover.jpg")
        if i % 5 == 0 or i == len(images):
            el = time.time() - t1
            print(f"  {i}/{len(images)}  {el/i:.2f} s/图  已用 {el/60:.1f} min", flush=True)

    elapsed = time.time() - t1
    nc = len(tax.classes)

    def write_csv(path: Path, rows: list[dict], fields: list[str]) -> None:
        with path.open("w", encoding="utf-8-sig", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            w.writerows(rows)

    write_csv(out_dir / "candidates.csv", in_rows,
              ["image", "class_id", "query", "label", "conf", "bbox"])

    # 表外汇总（按 label 聚合，而不是逐框）
    oot_summary = [{
        "label": lab, "count": n, "images": len(oot_images[lab]),
        "image_rate": round(len(oot_images[lab]) / len(images), 3),
        "sample_image": oot_samples[lab],
    } for lab, n in oot_count.most_common()]
    write_csv(out_dir / "out_of_taxonomy.csv", oot_summary,
              ["label", "count", "images", "image_rate", "sample_image"])

    lines = [
        "# 类别发现报告", "",
        f"- 图像：{len(images)} 张（`{img_root.relative_to(REPO_ROOT) if img_root.is_relative_to(REPO_ROOT) else img_root}`）",
        f"- 模型：`{args.model}`（**每次单 prompt**）",
        f"- 类别表：{nc} 类；表内待查词 {len(in_tax)} 个；表外候选词 {len(oot_words)} 个",
        f"- 耗时：{elapsed / 60:.1f} 分钟（{elapsed / len(images):.2f} s/图）",
        "",
        "## 表内检出（candidates.csv）", "",
    ]
    by_cls = Counter(r["class_id"] for r in in_rows)
    img_by_cls: dict[int, set] = defaultdict(set)
    for r in in_rows:
        img_by_cls[r["class_id"]].add(r["image"])
    lines += ["| id | 类别 | 框数 | 出现图 | 出图率 |", "|---|---|---|---|---|"]
    for cid, n in by_cls.most_common():
        lines.append(f"| {cid} | {tax.name(cid)} | {n} | {len(img_by_cls[cid])} | "
                     f"{len(img_by_cls[cid]) / len(images):.0%} |")
    zero = [tax.name(c["id"]) for c in tax.classes
            if not c.get("never_from_vlm") and not by_cls.get(c["id"])]
    lines += ["", f"表内零检出（{len(zero)}）：{', '.join(zero) if zero else '无'}", ""]

    lines += ["", "## ★ 表外候选（out_of_taxonomy.csv）", "",
              "**这些不在类别表内，但确实被检出**。它们当前会被静默漏掉——",
              "这份清单就是把「静默漏掉」变成「显式报告」。", ""]
    if oot_summary:
        lines += ["| 标签 | 框数 | 出现图 | 出图率 |", "|---|---|---|---|"]
        for r in oot_summary[:40]:
            lines.append(f"| {r['label']} | {r['count']} | {r['images']} | {r['image_rate']:.0%} |")
    else:
        lines.append("**未发现任何表外物件。**")

    if mismatch:
        lines += ["", "## 标签异常（返回标签 != 所问 query）", "",
                  "通常由 tokenizer 破损造成。异常标签会落入「表外」，不会被错误映射，",
                  "但仍需关注：", ""]
        for lab, n in mismatch.most_common(15):
            lines.append(f"- `{lab}` × {n}")

    (out_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")

    print(f"\n完成 {len(images)} 张，{elapsed / 60:.1f} min（{elapsed / len(images):.2f} s/图）")
    print(f"表内检出 {len(in_rows)} 框，覆盖 {len(by_cls)} 个类别")
    print(f"\n★ 表外候选 {len(oot_summary)} 个标签：")
    for r in oot_summary[:15]:
        print(f"    {r['label']:24s} {r['count']:>4} 框 / {r['images']:>3} 图 "
              f"({r['image_rate']:.0%})")
    if not oot_summary:
        print("    **未发现任何表外物件** —— 若预期有，说明门槛过严")
    if mismatch:
        print(f"\n标签异常 {sum(mismatch.values())} 次（tokenizer 破损），"
              f"如 {list(mismatch)[:3]}")
    if args.overlay:
        print(f"\n叠加图（绿=表内 / 橙=表外）：{ov_dir.relative_to(REPO_ROOT)}")
    print(f"报告：{(out_dir / 'report.md').relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
