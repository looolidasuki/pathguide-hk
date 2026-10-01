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
# 默认权重 = **当前已发布的那一份**（runs/pg_poc3，3 类）。
#
# 这里必须指向已发布的 run，不能指向「最近跑过的 run」：
# 旧的 runs/pg_review_v0 是**24 类**模型，而类别表后来扩到了 48 类、旧表已作废。
# 若默认值还指着它，一条 `python export_tflite.py` 就会导出一个
# 类别数与 classes.json 对不上的模型——而且**不报错**，只是每个框都标错类。
DEFAULT_WEIGHTS = REPO_ROOT / "runs" / "pg_poc3" / "weights" / "best.pt"
ASSETS_MANIFEST = REPO_ROOT / "app" / "assets" / "models" / "detector.json"
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
                         declared: list[int] | None = None,
                         names: dict[int, str] | None = None) -> str:
    """把输出形状翻译成人话，并检查它是否符合 Kotlin 解码器的假设。

    [declared] 是 App 侧 `modelClassIds` 声明的映射表：模型类别数不等于项目
    类别表时，靠它把本地索引翻成真实 id。长度必须与模型类别数一致。
    """
    if len(shape) != 3:
        return f"  !! 输出应为 3 维，实际 {shape}——Kotlin 解码器会拒绝这个模型"
    d1, d2 = shape[1], shape[2]
    # ★ 「锚点优先」当且仅当 anchors 落在第 1 维，即 d1 > d2。
    #
    # 这里曾经写成 `d1 < d2`，并把标签写成「（转置）」——**恰好反了**：
    # 本项目的模型输出是 [1, 5, 3549]，按旧写法会被说成「[1, anchors, 4+nc]」，
    # 而它其实是通道优先。Kotlin 解码器里那句 `transposed = d1 < d2`
    # 就是照着这条信息写的，于是真机上整片框都读错通道（见
    # docs/superpowers/plans/2026-09-23-decode-silent-failures.md 第 2.1 节）。
    #
    # 教训：**一处错的名字会生产出另一处错的代码。**
    # `scripts/check_tflite_decode.py` 会同时核对这里与 Kotlin 那处，
    # 两边的运算符必须都是 `>`。
    anchors_first = d1 > d2
    channels = min(d1, d2)
    anchors = max(d1, d2)
    classes = channels - 4
    lines = [
        f"  通道布局："
        f"{'[1, anchors, 4+nc]（锚点优先）' if anchors_first else '[1, 4+nc, anchors]（通道优先）'}"
        f"   -> Kotlin 的 transposed 应为 {str(anchors_first).lower()}",
        f"  锚点数   ：{anchors}",
        f"  类别数   ：{classes}（= 通道 {channels} - 4）",
    ]
    if declared is not None and classes != num_classes:
        # 模型类别数不等于项目类别表：必须靠 model_class_map.dart 的映射表，
        # 而且**长度必须恰好等于模型类别数**，否则 App 会拒绝加载（故意不猜）。
        if len(declared) == classes:
            lines.append(
                f"  ✓ 映射表长度相符：App 的 modelClassIds 有 {len(declared)} 项 "
                f"{declared}，模型 {classes} 类，一一对应"
            )
            labels = [(names or {}).get(i, f"id{i}") for i in declared]
            lines.append(f"     即本地索引 0..{classes - 1} 分别对应 {labels}")
        elif not declared:
            lines.append(
                f"  !! App 的 modelClassIds 是空表（表示「不需要映射」），"
                f"但模型是 {classes} 类、项目类别表是 {num_classes} 类——"
                f"App 会拒绝加载"
            )
        else:
            lines.append(
                f"  !! App 的 modelClassIds 有 {len(declared)} 项，模型 {classes} 类："
                f"长度不符，App 会拒绝加载。请改 "
                f"app/lib/vision/model_class_map.dart"
            )
    if num_classes is not None and classes == num_classes and declared:
        lines.append(
            f"  !! 模型类别数已等于项目类别表（{num_classes}），"
            f"modelClassIds 应为空表，但现在是 {declared}"
        )
    if anchors < 100:
        lines.append(f"  !! 锚点数 {anchors} 异常偏小，模型可能没导出成功")
    return "\n".join(lines)


def bundled_manifest_ids() -> tuple[int, list[int]] | None:
    """读 App 当前**内置清单**里的类别数与映射，用于导出时交叉核对。

    以前这里读的是 `model_class_map.dart` 里的编译期常量。那不行：
    模型将来要从服务器下发，映射必须**跟着模型走**，所以它的归属是清单
    （`app/assets/models/detector.json`），而不是 Dart 源码里的常量。
    """
    p = REPO_ROOT / "app" / "assets" / "models" / "detector.json"
    if not p.exists():
        return None
    import json
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None
    ids = d.get("modelClassIds")
    if not isinstance(ids, list):
        return None
    return int(d.get("modelClassCount", len(ids))), [int(x) for x in ids]


def write_manifest(model_path: Path, out_path: Path, dataset_dir: Path | None,
                   imgsz: int, version: str, map50: float | None) -> int:
    """写模型清单：**模型下发的单位是「模型 + 它的类别映射」**。

    ## 为什么清单必须存在（本项目最容易踩的静默故障）

    TFLite 里**没有**「这个模型是用哪些 class-id 训的」这个元数据。
    以前这份信息写死在 `model_class_map.dart` 的一个常量里：本地开发没问题，
    但模型一旦能从服务器下发，**服务端换了类别集而 App 不知道**，
    于是每个框的名字都是错的，**而且不报错**。

    所以清单必须带 `modelClassIds`，而它的来源是**训练数据集的
    `classes.json`**（那份文件的 `original_id` 就是真实 id），不是手写。

    返回 0 表示成功。
    """
    import hashlib
    import json

    if dataset_dir is None or not (dataset_dir / "classes.json").exists():
        print(f"  !! 找不到 {dataset_dir}/classes.json，无法生成清单")
        print("     清单里的 modelClassIds 必须来自训练数据集的类别表，不能手写")
        return 1
    ds = json.loads((dataset_dir / "classes.json").read_text(encoding="utf-8"))
    classes = sorted(ds["classes"], key=lambda c: c["id"])
    # 单类数据集用 original_id 记真实 id；多类数据集的 id 本身就是本地索引
    ids = [int(c.get("original_id", c["id"])) for c in classes]

    data = model_path.read_bytes()
    manifest = {
        "format": 1,
        "version": version,
        "file": model_path.name,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "inputSize": imgsz,
        "modelClassCount": len(ids),
        "modelClassIds": ids,
        "trainedAt": version.split(".")[0],
        "map50": map50,
    }
    # sourceDataset 只用于人追溯，**不进清单**：清单是要下发到手机上的资产，
    # 里面出现 C:\Users\... 这种本机绝对路径既没意义又会泄露开发机布局。
    # 追溯信息改由打印出来（见下面），需要的人从构建日志里取。
    try:
        dataset_label = str(dataset_dir.relative_to(REPO_ROOT))
    except ValueError:
        dataset_label = dataset_dir.name
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    print(f"已写模型清单 {out_path.relative_to(REPO_ROOT)}")
    print(f"  {manifest['modelClassCount']} 类，modelClassIds={ids}，"
          f"输入 {imgsz}，{len(data) / 1e6:.2f} MB")
    print(f"  sha256 {manifest['sha256'][:16]}…（App 侧据此校验下载完整性）")
    print(f"  映射来源数据集：{dataset_label}（不写进清单，只留在日志里）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default=str(DEFAULT_WEIGHTS))
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--no-int8", action="store_true", help="只导 float32")
    ap.add_argument("--copy-to-assets", action="store_true", default=True,
                    help="把导出的 tflite 复制到 app/assets/models/detector.tflite")
    ap.add_argument("--no-copy", dest="copy_to_assets", action="store_false")
    ap.add_argument("--dataset", default="data/dataset_poc3",
                    help="训练数据集目录（含 classes.json）。清单里的 modelClassIds 从这里取")
    ap.add_argument("--deploy", default="int8", choices=["int8", "float32"],
                    help="部署哪一个：int8（默认，实测同精度更快）或 float32")
    ap.add_argument("--version", default=None, help="清单版本号，默认取当天日期")
    ap.add_argument("--map50", type=float, default=None,
                    help="本次训练的 mAP50，仅写进清单便于现场判断模型质量（可选）")
    ap.add_argument("--no-manifest", action="store_true",
                    help="不生成模型清单（仅调试用；正式导出必须生成）")
    args = ap.parse_args()

    weights = Path(args.weights)
    if not weights.exists():
        print(f"权重不存在：{weights}")
        return 1

    # 类别数以 configs/classes.json 为准，用来交叉校验输出形状。
    import json
    classes_path = REPO_ROOT / "configs" / "classes.json"
    num_classes = None
    class_names: dict[int, str] = {}
    if classes_path.exists():
        with classes_path.open(encoding="utf-8") as f:
            items = json.load(f)["classes"]
        num_classes = len(items)
        class_names = {c["id"]: c["name_en"] for c in items}

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
    bundled = bundled_manifest_ids()
    declared = bundled[1] if bundled else None
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
        print(explain_output_shape(info["output_shape"], num_classes, declared,
                                   class_names))

    if args.copy_to_assets:
        # 部署哪一个：实测 416 int8 与 float32 精度几乎一致（IoU 0.966 vs 0.963）
        # 但 int8 更快（268 ms vs 324 ms）且体积 1/3.7，所以默认部署 int8。
        want = args.deploy
        src = outputs.get(want) or outputs.get("float32")
        if src and src.exists():
            ASSETS_MODEL.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, ASSETS_MODEL)
            print(f"\n已复制 {want} 到 {ASSETS_MODEL.relative_to(REPO_ROOT)} "
                  f"({ASSETS_MODEL.stat().st_size / 1e6:.2f} MB)")
        else:
            print(f"\n没有可复制的产物（要 {want}），跳过。")
            problems += 1

    # 清单必须与模型**一起**产出：App 靠它把本地索引翻成真实 id。
    if not args.no_manifest and ASSETS_MODEL.exists():
        from datetime import date
        version = args.version or f"{date.today().isoformat()}.1"
        ds_dir = Path(args.dataset)
        if not ds_dir.is_absolute():
            ds_dir = REPO_ROOT / ds_dir
        rc = write_manifest(ASSETS_MODEL, ASSETS_MANIFEST, ds_dir,
                            args.imgsz, version, args.map50)
        if rc == 0 and bundled:
            if bundled[1] != json.loads(ASSETS_MANIFEST.read_text(encoding="utf-8"))["modelClassIds"]:
                print("  注意：App 内置清单的 modelClassIds 与本次导出不同，"
                      "新清单已覆盖到 assets（App 下次构建即生效）。")
        problems += rc

    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
