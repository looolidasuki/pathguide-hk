"""对照实验：用「复核前」的预标标签训练同一配置，量化人工复核带来的变化。

只换标签，其余全部相同（同一批 44 张图、同一 seed=42、同一划分、同样 100 epochs
/ imgsz 416 / batch 8 / yolo11n）。因为单来源等间隔取样是确定性的，两份数据的
train/val/test 划分完全一致，对照是干净的。

用法：
    python scripts/ablation_pre_review.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import env_setup  # noqa: F401  必须在 ultralytics 之前导入：重定向 YOLO_CONFIG_DIR

REPO_ROOT = Path(__file__).resolve().parents[1]
ABLATION_DIR = REPO_ROOT / "data" / "_ablation_pre_review"


def main() -> int:
    from ultralytics import YOLO

    yaml_path = ABLATION_DIR / "_datasets" / "pathguide.yaml"
    if not yaml_path.exists():
        print(f"未找到对照数据集 yaml：{yaml_path}")
        return 1

    model = YOLO("yolo11n.pt")
    model.train(
        data=str(yaml_path),
        epochs=100,
        imgsz=416,
        batch=8,
        workers=0,
        seed=42,
        project=str(REPO_ROOT / "runs"),
        name="pg_ablation_prereview",
        exist_ok=True,
        verbose=False,
        plots=False,
    )

    best = REPO_ROOT / "runs" / "pg_ablation_prereview" / "weights" / "best.pt"
    metrics = YOLO(str(best)).val(data=str(yaml_path), split="test", imgsz=416, workers=0)

    summary = {
        "run": "ablation_pre_review",
        "labels": "复核前（三阶段预标）",
        "mAP50": float(metrics.box.map50),
        "mAP50_95": float(metrics.box.map),
        "macro_P": float(metrics.box.mp),
        "macro_R": float(metrics.box.mr),
        "per_class": {
            metrics.names[int(c)]: {
                "P": float(metrics.box.p[i]),
                "R": float(metrics.box.r[i]),
                "mAP50": float(metrics.box.ap50[i]),
            }
            for i, c in enumerate(metrics.box.ap_class_index)
        },
    }
    out = REPO_ROOT / "runs" / "ablation_pre_review.json"
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
