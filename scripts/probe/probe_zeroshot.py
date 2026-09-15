"""用 YOLO-World 零样本探测：哪些日常物件能被识别出来。

定位：**可行性探测（spike）专用，throwaway**。

设计要点——为什么每个物件单独跑一条 prompt：
    对某物件 X，把 YOLO-World 的类别集合设为**单条**「X 的 prompt」，
    再对属于 X 的图片推理。于是：
        检出率 = 在 X 的图片里检到该类别的比例
        平均置信度 = 检出时的平均 conf
    若把多个 prompt 同时设入，模型会在它们之间竞争，得到的数字无法归因。

输出：
    <out>/report.json   机读
    <out>/report.md     人读结论表

用法：
    python scripts/probe/probe_zeroshot.py --images data/probe/hk --out data/probe
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# env_setup 位于 scripts/，而本脚本在 scripts/probe/，需显式加入搜索路径
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import env_setup  # noqa: E402  必须在 ultralytics 之前导入

WEIGHTS = "yolov8s-world.pt"
CONF_FLOOR = 0.25      # 判定"检出"的置信度下限
CONF_SWEEP = [0.10, 0.15, 0.25, 0.35, 0.50]

# 探测用词表：键与 data/probe/hk/<key>/ 目录名一致。
# "prompts" 为该物件的多组说法——**必须测多组**：CLIP 对生僻词很敏感，
# 单组 prompt 失败可能是"没问对"而不是"认不出"，二者结论完全不同。
PROMPTS: dict[str, dict] = {
    "trash_bin": {"zh": "垃圾桶", "prompts": [
        "a trash bin", "a rubbish bin", "a litter bin", "a garbage can", "a waste basket",
    ]},
    "post_box": {"zh": "邮筒", "prompts": ["a post box", "a mailbox", "a red pillar box"]},
    "phone_booth": {"zh": "电话亭", "prompts": ["a telephone booth", "a phone booth", "a public telephone"]},
    "bench": {"zh": "长椅", "prompts": ["a bench", "a public bench", "a park bench"]},
    "planter": {"zh": "花槽", "prompts": [
        "a planter", "a flower pot", "a plant container", "a roadside planter",
        "a potted plant", "a tree pit",
    ]},
    "traffic_light": {"zh": "红绿灯", "prompts": [
        "a traffic light", "traffic lights", "a pedestrian crossing light", "a traffic signal",
    ]},
    "footbridge": {"zh": "行人天桥", "prompts": [
        "a footbridge", "a pedestrian bridge", "an overpass", "a walkway bridge",
        "a covered walkway", "an elevated walkway", "a pedestrian overpass",
        "footbridge entrance", "a bridge staircase", "a skybridge",
    ]},
    "escalator": {"zh": "自动扶梯", "prompts": [
        "an escalator", "escalators", "a moving staircase", "an escalator entrance",
    ]},
    "tactile_paving": {"zh": "触觉引路带", "prompts": [
        "tactile paving", "tactile paving on a sidewalk", "a blind guide path",
        "yellow tactile paving", "truncated domes on the ground", "a guide path for the blind",
    ]},
    "shop_sign": {"zh": "店铺招牌", "prompts": ["a shop sign", "a store sign", "a shop signboard", "a shop front"]},
    "fire_hydrant": {"zh": "消防栓", "prompts": ["a fire hydrant", "a red fire hydrant", "a street hydrant"]},
}

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def list_images(d: Path) -> list[Path]:
    if not d.exists():
        return []
    return sorted(p for p in d.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTS)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", default="data/probe/hk")
    ap.add_argument("--out", default="data/probe")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=CONF_FLOOR)
    args = ap.parse_args()

    images_root = REPO_ROOT / args.images
    out_root = REPO_ROOT / args.out
    out_root.mkdir(parents=True, exist_ok=True)

    available = {k: list_images(images_root / k) for k in PROMPTS}
    present = {k: v for k, v in available.items() if v}
    if not present:
        print(f"未在 {images_root} 找到任何图片。请先运行 fetch_commons.py。")
        return 1

    print("图片数量：")
    for k, v in available.items():
        print(f"  {k:16s} {len(v):4d}")
    skipped = [k for k, v in available.items() if not v]
    if skipped:
        print(f"\n无图片、将跳过：{skipped}")

    from ultralytics import YOLO

    model = YOLO(WEIGHTS)
    print(f"\n已加载 {WEIGHTS}；逐物件单 prompt 推理（{args.imgsz}px，conf 下限 {args.conf}）")

    results: dict[str, dict] = {}
    t0 = time.time()

    for key, paths in present.items():
        variants: list[str] = PROMPTS[key]["prompts"]
        per_variant: list[dict] = []

        for prompt in variants:
            try:
                model.set_classes([prompt])
            except Exception as exc:  # noqa: BLE001
                print(f"    [WARN] set_classes 失败 ({prompt}): {type(exc).__name__}")
                continue
            preds = model.predict(
                [str(p) for p in paths],
                imgsz=args.imgsz, conf=min(CONF_SWEEP) / 2, verbose=False,
            )
            top: list[float] = []
            for r in preds:
                confs = r.boxes.conf.tolist() if r.boxes is not None and len(r.boxes) else []
                top.append(max(confs) if confs else 0.0)
            n = len(top) or 1
            per_variant.append({
                "prompt": prompt,
                "hit_rate": round(sum(1 for x in top if x >= args.conf) / n, 4),
                "mean_top_conf": round(sum(top) / n, 4),
                "hits_by_conf": {str(c): round(sum(1 for x in top if x >= c) / n, 4)
                                 for c in CONF_SWEEP},
            })

        if not per_variant:
            continue
        best = max(per_variant, key=lambda v: (v["hit_rate"], v["mean_top_conf"]))
        results[key] = {
            "zh": PROMPTS[key]["zh"],
            "n_images": len(paths),
            "n_variants": len(per_variant),
            "best_prompt": best["prompt"],
            "best_hit_rate": best["hit_rate"],
            "best_mean_conf": best["mean_top_conf"],
            "worst_hit_rate": min(v["hit_rate"] for v in per_variant),
            "variants": per_variant,
        }
        print(f"  {key:16s} n={len(paths):4d}  最佳检出率={best['hit_rate']:.2f} "
              f"({'`' + best['prompt'] + '`'})  平均conf={best['mean_top_conf']:.3f}  "
              f"[{len(per_variant)} 组 prompt]")

    elapsed = time.time() - t0

    # ---- 报告 ----
    (out_root / "report.json").write_text(
        json.dumps({"conf_floor": args.conf, "conf_sweep": CONF_SWEEP,
                    "elapsed_s": round(elapsed, 1), "results": results},
                   ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    def verdict(rate: float, conf: float) -> str:
        """判定同时看检出率与置信度。

        只看检出率会被低阈值抬高的噪声误导：模型可能在近乎随机的低分上"检出"。
        """
        if rate >= 0.60 and conf >= 0.35:
            return "✅ 零样本可用"
        if rate >= 0.60:
            return "⚠️ 可检出但置信度低"
        if rate >= 0.30:
            return "⚠️ 需微调"
        if rate >= 0.10:
            return "❌ 弱（需大量实拍）"
        if conf < 0.05:
            return "❌ **零样本完全失效**（置信度≈噪声）"
        return "❌ 零样本失效"

    lines = [
        "# 日常物件零样本可辨识性探测报告",
        "",
        "> **这是可行性探测（spike）的产出，不是正式数据集评测。** 未标注真值框，",
        "> 因此给不出 mAP，也不含误报率。它回答的是：*这些物件能不能被零样本认出来。*",
        "",
        f"- 权重：`{WEIGHTS}`（YOLO-World-S）",
        f"- 图像：Wikimedia Commons **香港**分类，共 "
        f"{sum(len(v) for v in present.values())} 张（仅用于评测，不用于训练）",
        f"- 方法：**每个物件测多组 prompt 说法**，取最佳。这是必要的——",
        "  CLIP 对生僻词敏感，单组 prompt 失败可能是「没问对」而非「认不出」。",
        f"- 判定门槛：置信度 >= {args.conf}",
        f"- 耗时：{elapsed / 60:.1f} 分钟",
        "",
        "## 结论表（按最佳 prompt）",
        "",
        "| 物件 | 图片数 | 最佳检出率 | 平均置信度 | 最佳 prompt | 判定 |",
        "|---|---|---|---|---|---|",
    ]
    order = sorted(
        (k for k in PROMPTS if k in results),
        key=lambda k: (results[k]["best_hit_rate"], results[k]["best_mean_conf"]),
        reverse=True,
    )
    for key in order:
        r = results[key]
        lines.append(
            f"| {r['zh']} ({key}) | {r['n_images']} | **{r['best_hit_rate']:.2f}** | "
            f"{r['best_mean_conf']:.3f} | `{r['best_prompt']}` | "
            f"{verdict(r['best_hit_rate'], r['best_mean_conf'])} |"
        )
    for key in PROMPTS:
        if key not in results:
            n0 = len(available.get(key, []))
            lines.append(f"| {PROMPTS[key]['zh']} ({key}) | {n0} | — | — | — | 无可用图片 |")

    lines += ["", "## 各 prompt 变体明细", ""]
    for key in order:
        r = results[key]
        lines.append(f"### {r['zh']} ({key}) — {r['n_images']} 张，{r['n_variants']} 组说法")
        lines.append("")
        lines.append("| prompt | 检出率 | 平均置信度 |")
        lines.append("|---|---|---|")
        for v in sorted(r["variants"], key=lambda x: x["hit_rate"], reverse=True):
            marker = " ⭐" if v["prompt"] == r["best_prompt"] else ""
            lines.append(f"| `{v['prompt']}`{marker} | {v['hit_rate']:.2f} | {v['mean_top_conf']:.3f} |")
        lines.append("")

    lines += [
        "",
        "## 重要说明",
        "",
        "1. **本表衡量的是『可检出性』，不是精度。** 未标注真值框，因此无法给出 mAP。",
        "   未统计误报率——零样本模型可能在无关图像上乱出框。",
        "2. 图像全部来自 Commons 的香港分类，是**真实香港街景**，因此该表可直接反映",
        "   『零样本方案在香港能不能用』。",
        "3. 图片量普遍偏小，检出率的分母很小，数字波动大。",
        "   **这本身就是结论的一部分**：网上几乎没有香港日常物件的图。",
        "4. 图片许可多为 CC BY / CC BY-SA，署名信息见 `attribution.jsonl`；",
        "   若写入论文须列出作者与许可证。",
        "",
    ]
    (out_root / "report.md").write_text("\n".join(lines), encoding="utf-8")

    print(f"\n报告：{out_root / 'report.md'}")
    print(f"机读：{out_root / 'report.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
