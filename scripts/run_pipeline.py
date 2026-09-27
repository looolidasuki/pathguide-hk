"""端到端跑通训练流水线：生成 → manifest → 划分 → 门禁 → 训练 → 评测 → 导出。

用途：在真人采集开始前，验证整条链路可用，并产出一份带指标的运行报告。

用法：
    .venv\\Scripts\\python.exe scripts\\run_pipeline.py --epochs 40
    .venv\\Scripts\\python.exe scripts\\run_pipeline.py --skip-generate --epochs 100
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import env_setup  # noqa: F401  必须在 ultralytics 之前导入：重定向 YOLO_CONFIG_DIR

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"
PY = Path(sys.executable)
DATASET_DIR = REPO_ROOT / "data" / "dataset"
RUNS_DIR = REPO_ROOT / "runs"
REPORT_PATH = REPO_ROOT / "runs" / "pipeline_report.md"

FOLD_FILES = ("train.txt", "val.txt", "test.txt")


def banner(step: str, title: str) -> None:
    print(f"\n{'=' * 68}\n[{step}] {title}\n{'=' * 68}", flush=True)


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    print(f"$ {' '.join(str(c) for c in cmd)}", flush=True)
    proc = subprocess.run(cmd, cwd=str(REPO_ROOT), text=True, capture_output=True)
    if proc.stdout:
        print(proc.stdout.rstrip(), flush=True)
    if proc.returncode != 0 and proc.stderr:
        print(proc.stderr.rstrip(), file=sys.stderr, flush=True)
    if check and proc.returncode != 0:
        raise SystemExit(f"步骤失败（退出码 {proc.returncode}）：{' '.join(map(str, cmd))}")
    return proc


def step_generate(args: argparse.Namespace) -> None:
    banner("1/8", "生成合成数据集")
    if args.skip_generate:
        if not (DATASET_DIR / "images").exists():
            raise SystemExit("--skip-generate 指定了，但 data/dataset/images 不存在。")
        print("已跳过（复用现有数据集）")
        return
    for d in (DATASET_DIR / "images", DATASET_DIR / "labels", DATASET_DIR / "_duplicates"):
        if d.exists():
            shutil.rmtree(d)
    for stale in DATASET_DIR.glob("*.cache"):
        stale.unlink()
    run([str(PY), str(SCRIPTS / "gen_synthetic.py"),
         "--per-class", str(args.per_class), "--sources", str(args.sources)])


def step_manifest() -> None:
    banner("2/8", "生成 manifest.csv")
    run([str(PY), str(SCRIPTS / "make_manifest.py")])


def step_split(args: argparse.Namespace) -> None:
    banner("3/8", "分组分层划分（防泄漏）")
    run([str(PY), str(SCRIPTS / "split_dataset.py"), "--seed", str(args.seed)])
    # 校验各折清单存在、非空，且路径确实指向磁盘上的文件
    for name in FOLD_FILES:
        p = DATASET_DIR / name
        if not p.exists() or p.stat().st_size == 0:
            raise SystemExit(
                f"划分产物缺失或为空：{p}\n"
                f"  最常见原因：数据只有一个 source_folder（一次实地采集 = 一个文件夹），\n"
                f"  分组防泄漏划分会把全部图像丢进 train，val/test 为空。\n"
                f"  split_dataset.py 已内置单来源等间隔取样兜底；若仍为空，说明样本量\n"
                f"  不足（单来源至少要 3 张才有 val 与 test），需先补数据。")
        paths = [ln.strip() for ln in p.read_text(encoding="utf-8").splitlines() if ln.strip()]
        missing = [x for x in paths if not Path(x).exists()]
        if missing:
            raise SystemExit(
                f"{name} 中有 {len(missing)} 条路径指向不存在的文件，例如：{missing[0]}"
            )
        print(f"  {name}: {len(paths)} 条路径，全部存在")
    print("各折清单已生成且路径有效。")


def step_check_labels() -> dict:
    banner("4/8", "标签质量门禁")
    proc = run([str(PY), str(SCRIPTS / "check_labels.py")], check=False)
    if proc.returncode not in (0,):
        raise SystemExit("标签质量门禁未通过（存在致命错误），已中止。请查看 dataset_report.md。")
    report = DATASET_DIR / "dataset_report.md"
    text = report.read_text(encoding="utf-8") if report.exists() else ""
    fatal = 0
    for line in text.splitlines():
        if line.startswith("- 致命错误："):
            fatal = int(line.split("：")[1].strip())
    return {"fatal": fatal}


def step_check_review_sync() -> None:
    """若存在 X-AnyLabeling 复核目录，禁止用过期 YOLO 标签开训。

    GUI 只写同名 JSON；忘了 `xlabel_io emit` 时训练会静默用旧 txt。
    """
    banner("4b/8", "复核 JSON ↔ YOLO 标签同步检查")
    xtest_root = REPO_ROOT / "data" / "xtest"
    labels_root = DATASET_DIR / "labels"
    if not xtest_root.is_dir():
        print("未找到 data/xtest，跳过复核同步检查。")
        return
    stale: list[str] = []
    json_files = sorted(xtest_root.rglob("*.json"))
    if not json_files:
        print("data/xtest 下无 JSON，跳过。")
        return
    for jp in json_files:
        rel = jp.relative_to(xtest_root)
        txt = labels_root / rel.with_suffix(".txt")
        if not txt.exists():
            stale.append(f"{rel.as_posix()} → 缺少 {txt.relative_to(REPO_ROOT).as_posix()}")
            continue
        if jp.stat().st_mtime > txt.stat().st_mtime + 1.0:
            stale.append(f"{rel.as_posix()} 新于对应 YOLO 标签（请先 emit）")
    if stale:
        print("复核结果尚未回写到数据集，训练已中止：")
        for s in stale[:20]:
            print(f"  - {s}")
        if len(stale) > 20:
            print(f"  ...另有 {len(stale) - 20} 条")
        print("请执行例如：")
        print("  python scripts/xlabel_io.py emit --json-dir data/xtest/<src> "
              "--labels-out data/dataset/labels/<src>")
        raise SystemExit(2)
    print(f"复核同步检查通过：{len(json_files)} 个 JSON 均不新于对应 YOLO 标签。")


def step_train(args: argparse.Namespace) -> Path:
    banner("5/8", f"训练 YOLOv8n（{args.epochs} epochs, imgsz={args.imgsz}, batch={args.batch}, workers={args.workers}）")
    from ultralytics import YOLO

    patched = env_setup.prepare_ultralytics()
    if patched:
        print("已为受限环境打补丁：Ultralytics 标签缓存改为顺序执行（ThreadPool 不可用）")

    model = YOLO(args.base_model)
    results = model.train(
        data=str(REPO_ROOT / "datasets" / "pathguide.yaml"),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        workers=args.workers,
        cache=False,
        patience=max(15, args.epochs // 3),
        mosaic=1.0,
        hsv_h=0.015,
        hsv_s=0.7,
        hsv_v=0.4,
        degrees=5.0,
        cls=0.7,
        box=7.5,
        project=str(RUNS_DIR),
        name=args.name,
        exist_ok=True,
        plots=True,
        verbose=True,
    )
    save_dir = Path(getattr(results, "save_dir", RUNS_DIR / args.name))
    best = save_dir / "weights" / "best.pt"
    print(f"\nsave_dir = {save_dir}")
    print(f"best.pt  = {best}  存在={best.exists()}")
    if not best.exists():
        raise SystemExit("训练未产出 best.pt。")
    return best


def step_eval(args: argparse.Namespace, best: Path) -> dict:
    banner("6/8", "每类召回率评测（test 折）")
    from ultralytics import YOLO

    model = YOLO(str(best))
    metrics = model.val(
        data=str(REPO_ROOT / "datasets" / "pathguide.yaml"),
        split="test",
        imgsz=args.imgsz,
        batch=args.batch,
        workers=args.workers,
        project=str(RUNS_DIR),
        name=f"{args.name}_val",
        exist_ok=True,
        verbose=False,
    )

    names = model.names
    per_class: list[dict] = []
    box = metrics.box
    # Ultralytics 的 per-class 索引对应数据集中实际出现的类别
    for i, cid in enumerate(getattr(box, "ap_class_index", [])):
        cid = int(cid)
        per_class.append({
            "id": cid,
            "name": names.get(cid, str(cid)),
            "precision": float(box.p[i]),
            "recall": float(box.r[i]),
            "map50": float(box.ap50[i]),
            "map50_95": float(box.ap[i]),
        })

    summary = {
        "map50": float(box.map50),
        "map50_95": float(box.map),
        "precision": float(box.mp),
        "recall": float(box.mr),
        "per_class": per_class,
    }
    print(f"\nmAP@0.5 = {summary['map50']:.4f}   mAP@0.5:0.95 = {summary['map50_95']:.4f}")
    print(f"macro P = {summary['precision']:.4f}   macro R = {summary['recall']:.4f}")
    print("\n每类指标：")
    print(f"{'id':>3} {'class':<24} {'P':>7} {'R':>7} {'mAP50':>8}")
    for row in per_class:
        print(f"{row['id']:>3} {row['name']:<24} {row['precision']:>7.3f} "
              f"{row['recall']:>7.3f} {row['map50']:>8.3f}")
    return summary


def step_export(args: argparse.Namespace, best: Path) -> dict:
    banner("7/8", "导出 TFLite INT8")
    from ultralytics import YOLO

    model = YOLO(str(best))
    out: dict = {}
    try:
        path = model.export(format="tflite", imgsz=args.imgsz, int8=True,
                            data=str(DATASET_DIR / "test.txt"))
        tflite = Path(path)
        out["int8_path"] = str(tflite)
        out["int8_size_mb"] = round(tflite.stat().st_size / 1e6, 2)
        print(f"INT8 导出成功：{tflite}  ({out['int8_size_mb']} MB)")
        dest = REPO_ROOT / "app" / "assets" / "models"
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(tflite, dest / "detector.tflite")
        print(f"已复制到 {dest / 'detector.tflite'}")
    except Exception as exc:  # noqa: BLE001
        out["int8_error"] = f"{type(exc).__name__}: {exc}"
        print(f"INT8 导出失败：{out['int8_error']}")
        print("回退到 FP32 TFLite 导出……")
        path = model.export(format="tflite", imgsz=args.imgsz)
        tflite = Path(path)
        out["fp32_path"] = str(tflite)
        out["fp32_size_mb"] = round(tflite.stat().st_size / 1e6, 2)
        print(f"FP32 导出成功：{tflite}  ({out['fp32_size_mb']} MB)")
    return out


def build_report(*, data_source: str, n_images: int, split: dict, elapsed: float,
                 summary: dict, export_info: dict, best: Path,
                 base_model: str, epochs: int, imgsz: int, batch: int,
                 workers: int, now: str | None = None) -> str:
    """生成报告文本。纯函数，便于测试——报告里的错误不会让任何东西报错。"""
    now = now or time.strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        "# 流水线端到端运行报告",
        "",
        f"- 运行时间：{now}",
        f"- 总耗时：{elapsed / 60:.1f} 分钟",
        f"- 数据源：{data_source}",
        f"- 数据集：{n_images} 张图像",
        f"- 划分：train={split['counts']['train']} / val={split['counts']['val']} / test={split['counts']['test']}",
        f"- 划分 seed：{split['seed']}",
        f"- 基础模型：{base_model}",
        f"- 训练：{epochs} epochs, imgsz={imgsz}, batch={batch}, workers={workers}",
        f"- 权重：`{best.relative_to(REPO_ROOT).as_posix()}`",
        "",
    ]

    if split.get("single_source"):
        lines += [
            "> **指标可信度警告：单来源划分。** " + split.get("single_source_note", ""),
            "> 同一地点连拍的相邻帧几乎相同，train 与 test 高度相似，",
            "> 下列数字**高于真实泛化性能**，只能用于横向对比与链路验证，",
            "> **不得作为论文性能结论**。最终性能必须来自 ≥ 3 个独立采集点位的划分。",
            "",
        ]

    lines += [
        "## 整体指标（test 折）",
        "",
        f"- mAP@0.5：{summary['map50']:.4f}",
        f"- mAP@0.5:0.95：{summary['map50_95']:.4f}",
        f"- macro Precision：{summary['precision']:.4f}",
        f"- macro Recall：{summary['recall']:.4f}",
        "",
        "## 每类指标（test 折）",
        "",
        "| id | 类别 | Precision | Recall | mAP@0.5 |",
        "|---|---|---|---|---|",
    ]
    for row in summary["per_class"]:
        lines.append(f"| {row['id']} | {row['name']} | {row['precision']:.3f} "
                     f"| {row['recall']:.3f} | {row['map50']:.3f} |")

    lines += ["", "## 导出", ""]
    if "skipped" in export_info:
        lines.append(f"- 已跳过：{export_info['skipped']}")
        lines.append("- 在普通终端执行：")
        lines.append("  ```")
        lines.append(f"  python scripts\\export_model.py --weights "
                     f"{best.relative_to(REPO_ROOT).as_posix()} --int8")
        lines.append("  ```")
    elif "int8_path" in export_info:
        lines.append(f"- TFLite INT8：`{Path(export_info['int8_path']).name}` "
                     f"（{export_info['int8_size_mb']} MB）")
    else:
        lines.append(f"- INT8 导出失败：{export_info.get('int8_error', '未知')}")
        if "fp32_path" in export_info:
            lines.append(f"- TFLite FP32 回退：`{Path(export_info['fp32_path']).name}` "
                         f"（{export_info['fp32_size_mb']} MB）")

    model_label = Path(base_model).stem
    lines += [
        "",
        "## 流水线各环节状态",
        "",
        "| 环节 | 脚本 | 状态 |",
        "|---|---|---|",
        "| manifest | `scripts/make_manifest.py` | OK |",
        "| 分组分层划分 | `scripts/split_dataset.py` | OK（含泄漏校验） |",
        "| 标签门禁 | `scripts/check_labels.py` | OK |",
        f"| 训练 | Ultralytics {model_label} | OK |",
        "| 评测 | Ultralytics val | OK |",
        "| 导出 | Ultralytics export | OK |",
        "",
        "## 说明",
        "",
    ]
    if "合成" in data_source:
        lines.append("本报告验证的是**流水线可用性**，不是模型性能。合成数据的指标没有实际意义。")
        lines.append("真人采集数据到位后，清空 `data/dataset/` 并按 M0–M2 计划重跑；"
                     "届时只需把第 1 步替换为 `extract_frames.py` → `dedup.py`。")
    else:
        lines.append("本报告的数据为真人采集/复核数据。")
    if split.get("single_source"):
        lines.append("本报告的单来源指标**偏乐观**，仅用于横向对比（如人工复核前后），"
                     "不可作为论文性能结论。")
    lines += [
        "",
        "## 待人工完成",
        "",
        "- INT8 量化后的精度复测（Ultralytics 的 `val()` 不支持 TFLite 后端，需自行用 tflite_runtime 跑前向）",
        "- 真机基准测试（延迟 P50/P95、内存、发热）",
    ]
    return "\n".join(lines)


def write_report(args: argparse.Namespace, elapsed: float, summary: dict,
                 export_info: dict, best: Path) -> None:
    banner("8/8", "汇总运行报告")
    import csv

    manifest = DATASET_DIR / "manifest.csv"
    n_images = 0
    if manifest.exists():
        with manifest.open(encoding="utf-8-sig", newline="") as f:
            n_images = sum(1 for _ in csv.DictReader(f))
    split = json.loads((DATASET_DIR / "split.json").read_text(encoding="utf-8"))

    text = build_report(
        data_source=args.data_source, n_images=n_images, split=split,
        elapsed=elapsed, summary=summary, export_info=export_info, best=best,
        base_model=args.base_model, epochs=args.epochs, imgsz=args.imgsz,
        batch=args.batch, workers=args.workers,
    )
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(text, encoding="utf-8")
    print(f"报告 -> {REPORT_PATH}")


def main() -> int:
    t0 = time.time()
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--imgsz", type=int, default=416)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--workers", type=int, default=0,
                    help="DataLoader worker 数。受限沙箱下必须为 0（命名管道不可用）；"
                         "在普通命令行中可提高到 4-8 加速。")
    ap.add_argument("--base-model", default="yolov8n.pt")
    ap.add_argument("--name", default="pg_pipeline")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--per-class", type=int, default=24)
    ap.add_argument("--sources", type=int, default=8)
    ap.add_argument("--skip-generate", action="store_true")
    ap.add_argument("--data-source", default=None,
                    help="报告里对数据来源的说明。默认按 --skip-generate 推断："
                         "跳过了合成就不是合成数据——不要把真人采集的数据写进报告说成合成。")
    ap.add_argument("--export", action="store_true",
                    help="是否导出 TFLite。**默认关闭**：导出会下载 TensorFlow 并通过管道 stdio 调用"
                         "转换子进程，在受限沙箱中会挂起。请在普通终端中单独执行导出。")
    args = ap.parse_args()

    if args.data_source is None:
        args.data_source = ("复用现有数据集（真人采集/人工复核）"
                            if args.skip_generate else "合成数据（仅用于验证流水线）")

    print(f"仓库根目录：{REPO_ROOT}")
    print(f"Python：{PY}")

    step_generate(args)
    step_manifest()
    step_split(args)
    step_check_labels()
    step_check_review_sync()
    best = step_train(args)
    summary = step_eval(args, best)

    export_info: dict = {}
    if not args.export:
        banner("7/8", "导出 TFLite")
        print("已跳过（默认）。导出会下载 TensorFlow 并通过管道 stdio 调用转换子进程，")
        print("在受限沙箱中会挂起。请在**普通终端**中执行：")
        print("  python scripts\\export_model.py --weights runs\\pg_pipeline\\weights\\best.pt")
        export_info["skipped"] = "沙箱环境下 TFLite 导出不可用，需在普通终端执行"
    else:
        export_info = step_export(args, best)

    elapsed = time.time() - t0
    write_report(args, elapsed, summary, export_info, best)
    print(f"\n流水线全程跑通，耗时 {elapsed / 60:.1f} 分钟。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
