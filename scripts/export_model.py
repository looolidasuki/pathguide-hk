"""导出训练好的模型为 TFLite（INT8 / FP16 / FP32）。

**必须在普通终端中运行，不要在受限沙箱内运行。**
导出会下载 TensorFlow 并通过管道 stdio 调用转换子进程；受限环境禁止打开命名管道，
过程会挂起且无任何输出。

用法：
    python scripts\\export_model.py --weights runs\\pg_pipeline\\weights\\best.pt --int8
    python scripts\\export_model.py --weights runs\\pg_pipeline\\weights\\best.pt --fp16
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

import env_setup  # noqa: F401  必须在 ultralytics 之前导入

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
APP_MODELS = REPO_ROOT / "app" / "assets" / "models"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--int8", action="store_true", help="INT8 量化（需校准集，体积最小）")
    ap.add_argument("--fp16", action="store_true", help="FP16 量化（体积约为 FP32 一半）")
    ap.add_argument("--data", default=None, help="INT8 校准图像清单，默认用 test.txt")
    ap.add_argument("--no-copy", action="store_true", help="不复制到 app/assets/models/")
    args = ap.parse_args()

    weights = Path(args.weights)
    if not weights.exists():
        print(f"未找到权重：{weights}")
        return 1

    from ultralytics import YOLO

    model = YOLO(str(weights))
    kwargs: dict = {"format": "tflite", "imgsz": args.imgsz}
    if args.int8:
        calib = Path(args.data) if args.data else DATASET_DIR / "test.txt"
        if not calib.exists():
            print(f"INT8 需要校准集，未找到：{calib}")
            return 1
        kwargs.update(int8=True, data=str(calib))
        print(f"INT8 量化，校准集：{calib}")
    elif args.fp16:
        kwargs.update(half=True)
        print("FP16 量化")

    out = Path(model.export(**kwargs))
    size_mb = out.stat().st_size / 1e6
    print(f"\n导出成功：{out}")
    print(f"体积：{size_mb:.2f} MB")

    if not args.no_copy:
        APP_MODELS.mkdir(parents=True, exist_ok=True)
        dest = APP_MODELS / "detector.tflite"
        shutil.copy2(out, dest)
        print(f"已复制到：{dest}")

    print(
        "\n必须在普通终端中手动完成（Ultralytics 的 val() 不支持 TFLite 后端）：\n"
        "  用 tflite_runtime / tf.lite.Interpreter 对 test 折推理，得到 INT8 的 mAP@0.5，\n"
        "  与 FP32 对比；若精度损失 > 1.5%，回退 FP16：加 --fp16 重跑本脚本。\n"
        "  两个 mAP 值填入 runs/<name>/eval_final.md。"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
