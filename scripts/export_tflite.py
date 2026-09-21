"""导出 TFLite 模型，供 Android 端 LiteRT 使用。

## 为什么单独一个脚本 + 单独一个环境

导出链是 `PyTorch -> ONNX -> TensorFlow SavedModel -> TFLite`，其中
`onnx2tf` 需要 `tf_keras<=2.19.0` + TensorFlow 2.19 + 与之匹配的 protobuf。
这套依赖与训练环境（ultralytics + torch + numpy 2.x）**互相冲突**：
实测把它们装进同一个 venv 会让 `import tensorflow` 直接失败：

    AttributeError: 'MessageFactory' object has no attribute 'GetPrototype'

那是 protobuf 版本被搅乱的症状（TF 2.19 要 protobuf 4/5，onnx2tf 一带可能升到 6）。

所以本脚本**必须在 `.venv-export` 里运行**，不要在 `.venv` 里跑。
建环境的方法见 docs/superpowers/plans/2026-09-22-flutter-android-env.md。

## 它比一条 `model.export()` 多做三件事

1. **导出前后都校验**：把权重与 tflite 的输入/输出张量形状打出来。
   Android 侧的 Kotlin 解码器是**按形状反推**类别数与布局（`transposed`）的，
   形状不对必须在这里就发现，而不是等真机上「一个框都不出」。
2. **同时导 float32 与 int8**：float32 用来先跑通链路（精度无损），
   int8 用来测真实延迟与精度损失。
3. **把 tflite 复制到 app 的 assets**：省掉一次手工拷贝，
   手工拷贝是最容易拷错文件的一步。

用法：
    python scripts/export_tflite.py                       # 权重用默认路径
    python scripts/export_tflite.py --weights path/to/best.pt --imgsz 640
    python scripts/export_tflite.py --no-int8             # 只导 float32
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WEIGHTS = REPO_ROOT / "runs" / "pg_review_v0" / "weights" / "best.pt"
ASSETS_MODEL = REPO_ROOT / "app" / "assets" / "models" / "detector.tflite"


def describe_tensors(model_path: Path) -> dict:
    """读一个 .tflite 的输入输出张量形状。用来校验导出结果。"""
    try:
        from ai_edge_litert.interpreter import Interpreter  # LiteRT 新版包名
    except ImportError:
        try:
            from tensorflow.lite import Interpreter  # 旧包名
        except ImportError:
            from tflite_runtime.interpreter import Interpreter

    it = Interpreter(model_path=str(model_path))
    it.allocate_tensors()
    inp = it.get_input_details()[0]
    out = it.get_output_details()[0]
    return {
        "input_shape": list(inp["shape"]),
        "input_dtype": str(inp["dtype"]),
        "output_shape": list(out["shape"]),
        "output_dtype": str(out["dtype"]),
    }


def explain_output_shape(shape: list[int], num_classes: int | None,
                         single_class_id: int | None = None) -> str:
    """把输出形状翻译成人话，并检查它是否符合 Kotlin 解码器的假设。

    [single_class_id] 给出 App 侧配置的单类映射时，类别数 1 是**预期**的，
    不再报「与类别表不一致」——那条提示曾把正确的单类模型报成问题。
    """
    if len(shape) != 3:
        return f"  !! 输出应为 3 维，实际 {shape}——Kotlin 解码器会拒绝这个模型"
    d1, d2 = shape[1], shape[2]
    transposed = d1 < d2
    channels = min(d1, d2)
    anchors = max(d1, d2)
    classes = channels - 4
    lines = [
        f"  通道布局：{'[1, anchors, 4+nc]（转置）' if transposed else '[1, 4+nc, anchors]'}",
        f"  锚点数   ：{anchors}",
        f"  类别数   ：{classes}（= 通道 {channels} - 4）",
    ]
    if classes == 1 and single_class_id is not None:
        lines.append(
            f"  ✓ 单类模型（预期）：App 会把模型输出的 id 0 偏移到类别 {single_class_id}。"
            f"该偏移由 app/lib/vision/single_class_map.dart 的 singleClassProjectId 声明，"
            f"二者必须一致"
        )
        if num_classes is not None and single_class_id >= num_classes:
            lines.append(f"  !! 偏移 {single_class_id} 超出类别表范围（{num_classes} 类）")
        return "\n".join(lines)
    if num_classes is not None and classes != num_classes:
        lines.append(f"  !! 与 configs/classes.json 的 {num_classes} 类**不一致**——"
                     f"App 侧会按形状得到 {classes} 类，类别名会整体错位")
    if anchors < 100:
        lines.append(f"  !! 锚点数 {anchors} 异常偏小，模型可能没导出成功")
    return "\n".join(lines)


def dart_single_class_id() -> int | None:
    """从 Dart 侧读 App 配置的单类映射 id，用于形状校验时判断 1 类是否正常。

    这类「两处声明必须一致」的关系最容易漂移：模型是按 class-id 7 训的，
    而 App 里写的是不是 7 只能靠对齐。在这里交叉检查。
    """
    p = REPO_ROOT / "app" / "lib" / "vision" / "single_class_map.dart"
    if not p.exists():
        return None
    m = re.search(r"singleClassProjectId\s*=\s*(\d+)", p.read_text(encoding="utf-8"))
    return int(m.group(1)) if m else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default=str(DEFAULT_WEIGHTS))
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--no-int8", action="store_true", help="只导 float32")
    ap.add_argument("--copy-to-assets", action="store_true", default=True,
                    help="把导出的 tflite 复制到 app/assets/models/detector.tflite")
    ap.add_argument("--no-copy", dest="copy_to_assets", action="store_false")
    args = ap.parse_args()

    weights = Path(args.weights)
    if not weights.exists():
        print(f"权重不存在：{weights}")
        return 1

    # 类别数以 configs/classes.json 为准，用来交叉校验输出形状。
    import json
    classes_path = REPO_ROOT / "configs" / "classes.json"
    num_classes = None
    if classes_path.exists():
        with classes_path.open(encoding="utf-8") as f:
            num_classes = len(json.load(f)["classes"])

    from ultralytics import YOLO
    import ultralytics

    # 版本护栏：8.4.83 起 `format='tflite'` 被重定向到新的 'litert' 导出器，
    # 而那个只在 Linux x86 / macOS 上可用，Windows 上会断言失败：
    #     assert MACOS or (LINUX and not ARM64),
    #     "LiteRT export only supported on Linux x86 and macOS"
    # 与其等到导出中途才炸，不如在这里就说清楚。
    uv_version = ultralytics.__version__
    try:
        major, minor = (int(x) for x in uv_version.split(".")[:2])
    except ValueError:
        major, minor = 0, 0
    if (major, minor) > (8, 3):
        print(
            f"\n!! ultralytics 版本 {uv_version} 在 Windows 上无法导出 TFLite。\n"
            f"   8.4.83 起 format='tflite' 使用新的 litert 导出器，仅支持 Linux x86 / macOS。\n"
            f"   请在导出环境里降级：\n"
            f"     uv pip install --python <venv>\\Scripts\\python.exe \"ultralytics==8.3.253\"\n"
        )
        return 1

    model = YOLO(str(weights))
    outputs: dict[str, Path] = {}

    # 先导 float32：无量化损失，用来验证「模型能否在真机上出框」这件事本身。
    print("\n=== 导出 float32（用于先跑通链路）===")
    p32 = model.export(format="tflite", imgsz=args.imgsz, nms=False)
    fp32 = Path(p32)
    outputs["float32"] = fp32
    print(f"-> {fp32}  ({fp32.stat().st_size / 1e6:.2f} MB)")

    if not args.no_int8:
        print("\n=== 导出 int8（用于测真实延迟与精度损失）===")
        try:
            pint8 = model.export(format="tflite", imgsz=args.imgsz, nms=False, int8=True)
            pi = Path(pint8)
            outputs["int8"] = pi
            print(f"-> {pi}  ({pi.stat().st_size / 1e6:.2f} MB)")
        except Exception as exc:  # noqa: BLE001
            # int8 需要校准数据，失败不代表整件事失败。
            print(f"int8 导出失败（可忽略，float32 已可用）：{type(exc).__name__}: {exc}")

    print("\n=== 张量形状校验 ===")
    problems = 0
    single_id = dart_single_class_id()
    for name, path in outputs.items():
        if not path.exists():
            print(f"[{name}] 文件不存在：{path}")
            problems += 1
            continue
        try:
            info = describe_tensors(path)
        except Exception as exc:  # noqa: BLE001
            print(f"[{name}] 读取失败：{type(exc).__name__}: {exc}")
            problems += 1
            continue
        print(f"[{name}] {path.name}")
        print(f"  输入 ：{info['input_shape']} {info['input_dtype']}")
        print(f"  输出 ：{info['output_shape']} {info['output_dtype']}")
        print(explain_output_shape(info["output_shape"], num_classes, single_id))

    if args.copy_to_assets:
        src = outputs.get("float32")
        if src and src.exists():
            ASSETS_MODEL.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, ASSETS_MODEL)
            print(f"\n已复制到 {ASSETS_MODEL.relative_to(REPO_ROOT)} "
                  f"({ASSETS_MODEL.stat().st_size / 1e6:.2f} MB)")
            print("提示：先让 float32 在真机上出框，之后再换 int8 并对比精度。")
        else:
            print("\n没有可复制的 float32 产物，跳过。")
            problems += 1

    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
