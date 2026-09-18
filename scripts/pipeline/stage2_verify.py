"""三段式自动预标 —— 第二段：SAM 修框 + LocateAnything 裁剪验证。

**在 .venv-vlm 环境中运行**（需要 transformers 4.57.1 + LocateAnything）。

处理顺序（刻意如此，见下）：
    对第一段的每个候选框：
      1. 按原始框裁剪 -> 送 LocateAnything 问「这里面有没有 <类别>」
      2. 若模型说「没有」-> 判为误检，直接丢弃（**不再跑 SAM，省时间**）
      3. 若模型说「有」 -> 用 SAM 把框吸附到目标真实边界（**这才是 SAM 该出场的地方**）

为什么先验证再修框：
    修框是无条件信任第一段的定位。若该框本是误检，SAM 会把它"修"成一个边界漂亮的
    错误目标——更难被发现。先在裁剪图上问是/否，能挡掉误检，SAM 只处理确认存在的框。

为什么用裁剪而不是整图出框（实测决定）：
    整图 960x720 推理 63 s/张；裁剪 224x224 只需 6.8 s。瓶颈是视觉编码器 prefill，
    与 max_new_tokens / generation_mode 无关（实测 256->64 tokens 耗时不变）。
    裁剪验证快 9 倍，且语义正好是我们需要的问题。

用法：
    .venv-vlm\\Scripts\\python.exe scripts\\pipeline\\stage2_verify.py \\
        --proposals data/auto/proposals --images data/probe/hk --out data/auto/verified --limit 20
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
for p in (REPO_ROOT / "scripts", REPO_ROOT / "scripts" / "pipeline"):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from label_taxonomy import LabelTaxonomy  # noqa: E402
from la_output import exists_for, parse  # noqa: E402

CROP_SIZE = 336          # 稍大于 224，给上下文又不过度增加 prefill
LA_WEIGHTS = "nvidia/LocateAnything-3B"
SAM_WEIGHTS = "sam2.1_t.pt"


def crop_box(img, bbox: list[float], pad: float = 0.25):
    """按归一化框裁剪，外扩 pad 以给出上下文（纯裁剪会让模型失去尺度线索）。"""
    W, H = img.size
    x1, y1, x2, y2 = bbox
    bw, bh = x2 - x1, y2 - y1
    cx1 = max(0.0, x1 - bw * pad)
    cy1 = max(0.0, y1 - bh * pad)
    cx2 = min(1.0, x2 + bw * pad)
    cy2 = min(1.0, y2 + bh * pad)
    return img.crop((int(cx1 * W), int(cy1 * H), int(cx2 * W), int(cy2 * H)))


def cache_key(source: str, bbox: list[float], class_id: int) -> str:
    raw = f"{source}|{[round(v, 4) for v in bbox]}|{class_id}|{CROP_SIZE}"
    return hashlib.sha1(raw.encode()).hexdigest()[:20]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--proposals", default="data/auto/proposals")
    ap.add_argument("--images", default=None, help="图像根目录（默认从 proposals.jsonl 的 source 推断）")
    ap.add_argument("--out", default="data/auto/verified")
    ap.add_argument("--limit", type=int, default=None, help="只处理前 N 张图")
    ap.add_argument("--min-conf", type=float, default=0.20,
                    help="低于此置信度的框直接丢弃，**不做验证也不进复核清单**。"
                         "默认 0.20 是刻意压低：第一段已用 --conf 0.15 保召回，"
                         "若这里再设高（曾用 0.35）会把低阈值的收获取消掉——"
                         "实测垃圾桶 58 个框在 0.35 下只剩 33 个（-43%%），"
                         "而降到 0.25 可保留 42 个。**过滤应由 VLM 验证承担，而非阈值。**"
                         "被丢弃的框会记入 dropped_low_conf.csv 以供调参。")
    ap.add_argument("--trust-above", type=float, default=1.01,
                    help="置信度 >= 此值的框跳过 VLM 验证、直接采纳。"
                         "默认 1.01 表示**不跳过任何框**——全量验证。"
                         "试点实测：设为 0.70 会导致 43%% 的采纳框未经验证，"
                         "与「自动标注要有质量保证」的目的相悖，故默认关闭。"
                         "追求速度时可提高，但必须知道未验证比例。")
    ap.add_argument("--max-boxes-per-image", type=int, default=30,
                    help="单图最多验证多少个框（防某类框爆炸导致跑飞）")
    ap.add_argument("--refine", action="store_true", default=True,
                    help="对通过验证的框用 SAM 修框（默认开启）")
    ap.add_argument("--no-refine", dest="refine", action="store_false")
    args = ap.parse_args()

    prop_dir = REPO_ROOT / args.proposals
    jsonl = prop_dir / "proposals.jsonl"
    if not jsonl.exists():
        print(f"未找到 {jsonl}。请先运行 stage1_propose.py。")
        return 1

    out_dir = REPO_ROOT / args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    cache_path = out_dir / "vlm_cache.jsonl"
    verified_path = out_dir / "verified.jsonl"

    tax = LabelTaxonomy()
    id_to_name = {c["id"]: c["name_en"] for c in tax.classes}

    records: list[dict] = []
    with jsonl.open(encoding="utf-8") as f:
        for line in f:
            records.append(json.loads(line))
    if args.limit:
        records = records[: args.limit]
    print(f"待复核图像 {len(records)} 张")

    # ---- 载入模型 ----
    import torch
    from PIL import Image
    from transformers import AutoModel, AutoProcessor

    if args.refine:
        from ultralytics import SAM

    print("载入 LocateAnything-3B ...", flush=True)
    t0 = time.time()
    proc = AutoProcessor.from_pretrained(LA_WEIGHTS, trust_remote_code=True)
    model = AutoModel.from_pretrained(LA_WEIGHTS, dtype=torch.bfloat16,
                                      device_map="auto", trust_remote_code=True).eval()
    print(f"  LocateAnything 就绪 {time.time() - t0:.0f}s", flush=True)

    sam = None
    if args.refine:
        t0 = time.time()
        sam = SAM(SAM_WEIGHTS)
        print(f"  SAM 就绪 {time.time() - t0:.1f}s", flush=True)

    # ---- VLM 缓存（可断点续跑：长任务必需）----
    cache: dict[str, dict] = {}
    if cache_path.exists():
        with cache_path.open(encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line)
                    cache[e["key"]] = e
                except json.JSONDecodeError:
                    continue
        print(f"  已载入 VLM 缓存 {len(cache)} 条")

    cache_f = cache_path.open("a", encoding="utf-8")

    def vlm_verify(img, bbox, cid, source) -> tuple[bool | None, str]:
        """在裁剪图上问「有没有 <具体物件名>」。返回 (判定, 原始输出)。

        **用 tax.verify_query(cid) 而不是 name_en**：伞类名（street_obstacle）
        会把正确框判成误检——实测确认率 48% vs 'bin' 的 100%。
        """
        key = cache_key(source, bbox, cid)
        if key in cache:
            e = cache[key]
            return e["verdict"], e["raw"]
        query = tax.verify_query(cid)
        if query is None:
            return None, ""          # 该类不参与 VLM 验证（如 ambiguous_vertical）
        crop = crop_box(img, bbox).convert("RGB").resize((CROP_SIZE, CROP_SIZE))
        # 实测：必须是检测式说法；"Is there a X?" 会被回显成 ref 并框满全图
        q = f"Detect the following objects in the image: {query}."
        msgs = [{"role": "user", "content": [
            {"type": "image", "image": crop}, {"type": "text", "text": q}]}]
        text = proc.py_apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        images, videos = proc.process_vision_info(msgs)
        inp = proc(text=[text], images=images, videos=videos,
                   return_tensors="pt").to(model.device)
        with torch.no_grad():
            out = model.generate(
                pixel_values=inp["pixel_values"].to(torch.bfloat16),
                input_ids=inp["input_ids"], attention_mask=inp["attention_mask"],
                image_grid_hws=inp.get("image_grid_hws", None), tokenizer=proc.tokenizer,
                max_new_tokens=96, use_cache=True, generation_mode="fast",
                temperature=0.7, do_sample=True, top_p=0.9, repetition_penalty=1.1,
                verbose=False)
        raw = out[0] if isinstance(out, tuple) else out
        raw = raw if isinstance(raw, str) else str(raw)
        verdict = exists_for(raw, query, taxonomy=tax)
        cache_f.write(json.dumps({"key": key, "verdict": verdict, "raw": raw,
                                  "query": query}, ensure_ascii=False) + "\n")
        cache_f.flush()
        return verdict, raw

    # ---- 主循环 ----
    t_start = time.time()
    n_boxes = n_rejected = n_verified = n_skipped = n_accepted = 0
    vlm_calls = 0
    dropped_rows: list[dict] = []

    with verified_path.open("w", encoding="utf-8") as vf:
        for i, rec in enumerate(records, 1):
            src = Path(rec["source"])
            if not src.exists():
                src = (REPO_ROOT / rec["source"])
            if not src.exists():
                print(f"  [WARN] 图像缺失，跳过：{rec['source']}")
                continue
            img = Image.open(src)
            W, H = img.size
            dets = rec.get("detections", [])

            # 验证范围：默认全量。仅当置信度 >= trust_above 时才跳过。
            # 理由：stage-1 的置信度对「未见过的类别」并不可靠（实测 pedestrian 占 72%，
            # 却对 stairs/footbridge 几乎不出框），所以高置信度 ≠ 正确。
            to_verify = [d for d in dets if d["conf"] < args.trust_above]
            to_verify = sorted(to_verify, key=lambda d: -d["conf"])[: args.max_boxes_per_image]
            verify_ids = {id(d) for d in to_verify}

            kept: list[dict] = []
            for d in dets:
                n_boxes += 1
                if d["conf"] < args.min_conf:
                    n_skipped += 1
                    # 记录而非静默丢弃——否则无法判断门槛设得对不对
                    dropped_rows.append({
                        "image": rec["image"],
                        "class": id_to_name.get(d["class_id"], d["class_id"]),
                        "class_id": d["class_id"],
                        "conf": round(d["conf"], 4),
                        "prompt": d.get("prompt", ""),
                        "bbox": [round(v, 4) for v in d["bbox"]],
                        "reason": f"conf < min_conf({args.min_conf})",
                    })
                    continue
                verdict = None
                raw = ""
                if id(d) in verify_ids:
                    verdict, raw = vlm_verify(img, d["bbox"], d["class_id"], rec["source"])
                    vlm_calls += 1
                    n_verified += 1
                # verdict None（无法判定）不否决——保守起见保留，交第三段/人工
                if verdict is False:
                    n_rejected += 1
                    continue
                out_d = dict(d)
                out_d["vlm_verdict"] = verdict
                out_d["vlm_verified"] = id(d) in verify_ids

                if args.refine:
                    x1, y1, x2, y2 = d["bbox"]
                    px = [x1 * W, y1 * H, x2 * W, y2 * H]
                    try:
                        r = sam(str(src), bboxes=[px], device="cuda",
                                project=str(REPO_ROOT / ".tmp" / "sam_out"),
                                name="run", exist_ok=True, save=False, verbose=False)[0]
                        if r.masks is not None and len(r.masks.data):
                            m = r.masks.data[0].cpu().numpy() > 0.5
                            ys, xs = m.nonzero()
                            if len(xs):
                                nx1, ny1 = xs.min() / W, ys.min() / H
                                nx2, ny2 = xs.max() / W, ys.max() / H
                                # SAM 偶尔会吞掉整个画面；偏离过大则不采纳修框
                                inter_x = max(0.0, min(x2, nx2) - max(x1, nx1))
                                inter_y = max(0.0, min(y2, ny2) - max(y1, ny1))
                                inter = inter_x * inter_y
                                area_a = (x2 - x1) * (y2 - y1)
                                area_b = (nx2 - nx1) * (ny2 - ny1)
                                iou = inter / (area_a + area_b - inter) if (area_a + area_b - inter) > 0 else 0.0
                                if iou >= 0.30:
                                    out_d["bbox"] = [float(nx1), float(ny1), float(nx2), float(ny2)]
                                    out_d["refined"] = True
                                else:
                                    out_d["refined"] = False
                                out_d["refine_iou"] = round(iou, 4)
                    except Exception as exc:  # noqa: BLE001
                        out_d["refine_error"] = f"{type(exc).__name__}"
                kept.append(out_d)
                n_accepted += 1

            vf.write(json.dumps({"image": rec["image"], "source": rec["source"],
                                 "width": W, "height": H, "detections": kept},
                                ensure_ascii=False) + "\n")
            if i % 10 == 0 or i == len(records):
                el = time.time() - t_start
                print(f"  {i}/{len(records)}  VLM调用={vlm_calls}  "
                      f"拒绝={n_rejected}  已用 {el/60:.1f} min", flush=True)

    cache_f.close()
    elapsed = time.time() - t_start

    # 被丢弃的低置信框写盘——供调 min_conf
    import csv as _csv

    dropped_path = out_dir / "dropped_low_conf.csv"
    with dropped_path.open("w", encoding="utf-8-sig", newline="") as f:
        w = _csv.DictWriter(f, fieldnames=["image", "class", "class_id", "conf",
                                           "prompt", "bbox", "reason"])
        w.writeheader()
        w.writerows(dropped_rows)

    stats = {
        "images": len(records),
        "boxes_in": n_boxes,
        "boxes_accepted": n_accepted,
        "boxes_rejected": n_rejected,
        "boxes_skipped_low_conf": n_skipped,
        "vlm_verified": n_verified,
        "vlm_calls": vlm_calls,
        "elapsed_s": round(elapsed, 1),
        "sec_per_image": round(elapsed / max(len(records), 1), 2),
        "config": {"min_conf": args.min_conf, "trust_above": args.trust_above,
                   "refine": args.refine, "crop_size": CROP_SIZE},
    }
    (out_dir / "stage2_stats.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n完成 {len(records)} 张，{elapsed/60:.1f} min（{stats['sec_per_image']} s/张）")
    print(f"框：入 {n_boxes} -> 采纳 {n_accepted}，VLM 拒绝 {n_rejected}，低置信丢弃 {n_skipped}")
    print(f"VLM 调用 {vlm_calls} 次")
    if dropped_rows:
        print(f"低置信丢弃清单（供调 --min-conf）：{dropped_path.relative_to(REPO_ROOT)}")
    print(f"输出：{verified_path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
