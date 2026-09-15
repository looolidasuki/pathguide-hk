"""训练结果查看器：对任意已训练权重输出逐类指标报告。

用途：拿到一批数据训完之后，用一条命令看清"到底学到了什么、哪些类别不行"。

用法：
    # 评测最新一次训练（自动找 runs/ 下最近修改的 weights/best.pt）
    python scripts/report_training.py

    # 指定权重
    python scripts/report_training.py --weights runs/pg_v1/weights/best.pt

    # 指定划分（用 train 折算出来的指标没有意义，仅供排查；默认 test）
    python scripts/report_training.py --split val

产出：
    终端逐类指标表 + runs/<name>/eval_report.md + 两条曲线图 PNG
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import env_setup  # noqa: F401  必须在 ultralytics 之前导入

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNS_DIR = REPO_ROOT / "runs"
DEFAULT_YAML = REPO_ROOT / "datasets" / "pathguide.yaml"

# 毕设出口条件（见 spec §10 与计划 Task 12）
EXIT_CRITERIA = {
    "overall_map50_min": 0.60,
    "per_class_recall_min": 0.70,
    "critical_classes": [
        "footbridge_entrance", "stairs", "ramp", "elevator",
        "pedestrian", "street_obstacle", "step", "glass_door",
    ],
}


def find_latest_weights() -> Path | None:
    cands = sorted(RUNS_DIR.glob("*/weights/best.pt"),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    return cands[0] if cands else None


def read_results_csv(run_dir: Path) -> tuple[list[str], list[dict]]:
    p = run_dir / "results.csv"
    if not p.exists():
        return [], []
    with p.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return (list(rows[0].keys()) if rows else []), rows


def _series(rows: list[dict], name: str) -> list[float]:
    out: list[float] = []
    for r in rows:
        try:
            out.append(float(r[name]))
        except (KeyError, ValueError, TypeError):
            pass
    return out


def plot_training_curves(run_dir: Path) -> list[str]:
    """把 results.csv 画成 PNG，便于判断收敛与过拟合（终端无法显示图像）。"""
    header, rows = read_results_csv(run_dir)
    if not rows:
        return []
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return []

    epochs = ([int(float(r["epoch"])) for r in rows] if "epoch" in header
              else list(range(len(rows))))
    made: list[str] = []

    fig, ax = plt.subplots(1, 2, figsize=(13, 4.5))
    for k in ("train/box_loss", "train/cls_loss", "train/dfl_loss"):
        if k in header:
            ax[0].plot(epochs, _series(rows, k), label=k.split("/")[1])
    ax[0].set_title("training losses")
    ax[0].set_xlabel("epoch")
    ax[0].legend()
    ax[0].grid(alpha=.3)
    for k in ("val/box_loss", "val/cls_loss", "val/dfl_loss"):
        if k in header:
            ax[1].plot(epochs, _series(rows, k), label=k.split("/")[1])
    ax[1].set_title("validation losses")
    ax[1].set_xlabel("epoch")
    ax[1].legend()
    ax[1].grid(alpha=.3)
    fig.tight_layout()
    fig.savefig(run_dir / "curves_loss.png", dpi=110)
    plt.close(fig)
    made.append("curves_loss.png")

    fig, ax = plt.subplots(figsize=(9, 4.5))
    for k, lab in (("metrics/precision(B)", "precision"),
                   ("metrics/recall(B)", "recall"),
                   ("metrics/mAP50(B)", "mAP@0.5"),
                   ("metrics/mAP50-95(B)", "mAP@0.5:0.95")):
        if k in header:
            ax.plot(epochs, _series(rows, k), label=lab)
    ax.axhline(EXIT_CRITERIA["overall_map50_min"], ls="--", c="green", lw=1,
               label=f"exit gate mAP50={EXIT_CRITERIA['overall_map50_min']}")
    ax.set_title("validation metrics")
    ax.set_xlabel("epoch")
    ax.legend()
    ax.grid(alpha=.3)
    fig.tight_layout()
    fig.savefig(run_dir / "curves_metrics.png", dpi=110)
    plt.close(fig)
    made.append("curves_metrics.png")
    return made


def diagnose(rows: list[dict], summary: dict) -> list[str]:
    """根据曲线自动判断过拟合/欠拟合，并给出下一步。"""
    notes: list[str] = []
    if not rows:
        return notes

    box = _series(rows, "train/box_loss")
    vbox = _series(rows, "val/box_loss")
    m50 = _series(rows, "metrics/mAP50(B)")

    if len(m50) >= 10:
        best_i = max(range(len(m50)), key=lambda i: m50[i])
        best, last = m50[best_i], m50[-1]
        if best > 0 and (best - last) / best > 0.10:
            notes.append(
                f"[过拟合] mAP@0.5 在第 {best_i + 1} epoch 见顶 ({best:.4f})，之后降到 "
                f"{last:.4f}（-{(best - last) / best:.0%}）。"
                "处置：优先增加数据量，其次用 early stopping。"
            )
        elif best_i >= len(m50) - 3:
            notes.append(
                f"[未收敛] mAP@0.5 仍在上升（最佳在第 {best_i + 1} / {len(m50)} epoch）。"
                "可继续训练更多轮次。"
            )

    if box and vbox and len(box) == len(vbox) and len(box) > 5:
        tail_t = sum(box[-5:]) / 5
        tail_v = sum(vbox[-5:]) / 5
        if tail_v > tail_t * 1.6:
            notes.append(
                f"[泛化不佳] 验证损失明显高于训练损失（{tail_v:.3f} vs {tail_t:.3f}）。"
                "通常是数据量不足，或训练/验证分布不一致。"
            )

    if summary.get("map50", 0) < 0.05 and summary.get("per_class"):
        notes.append(
            "[先查数据] 整体 mAP@0.5 极低。**先查数据而不是模型**："
            "标签目录是否镜像了 images/ 结构、类别 id 是否在范围内、"
            "评测折是否真的含正样本。跑 scripts/check_labels.py。"
        )
    return notes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default=None, help="默认自动选取 runs/ 下最新的 best.pt")
    ap.add_argument("--data", default=str(DEFAULT_YAML))
    ap.add_argument("--split", default="test", choices=["train", "val", "test"])
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--workers", type=int, default=0)
    ap.add_argument("--no-plot", action="store_true")
    args = ap.parse_args()

    weights = Path(args.weights) if args.weights else find_latest_weights()
    if weights is None or not weights.exists():
        print("未找到任何权重。请先训练，或用 --weights 指定路径。")
        print(f"（已在 {RUNS_DIR} 下查找 */weights/best.pt）")
        return 1

    run_dir = weights.parent.parent
    print(f"权重    : {weights.relative_to(REPO_ROOT)}")
    print(f"训练目录: {run_dir.relative_to(REPO_ROOT)}")
    print(f"评测折  : {args.split}\n")

    header, rows = read_results_csv(run_dir)
    if rows:
        print(f"results.csv: {len(rows)} 个 epoch，最后一行：")
        last = rows[-1]
        for k in ("epoch", "metrics/precision(B)", "metrics/recall(B)",
                  "metrics/mAP50(B)", "metrics/mAP50-95(B)"):
            if k in last:
                print(f"  {k:26s} = {last[k]}")
        print()

    from ultralytics import YOLO

    model = YOLO(str(weights))
    metrics = model.val(
        data=args.data, split=args.split, imgsz=args.imgsz,
        batch=args.batch, workers=args.workers,
        project=str(RUNS_DIR), name=f"{run_dir.name}_report", exist_ok=True, verbose=False,
    )

    names = model.names
    box = metrics.box
    ap_index = [int(x) for x in getattr(box, "ap_class_index", [])]
    per_class = []
    for i in range(len(names)):
        if i in ap_index:
            idx = ap_index.index(i)
            per_class.append({"id": i, "name": names.get(i, str(i)),
                              "precision": float(box.p[idx]), "recall": float(box.r[idx]),
                              "map50": float(box.ap50[idx]), "map50_95": float(box.ap[idx])})
        else:
            per_class.append({"id": i, "name": names.get(i, str(i)),
                              "precision": None, "recall": None,
                              "map50": None, "map50_95": None})

    summary = {
        "map50": float(box.map50), "map50_95": float(box.map),
        "precision": float(box.mp), "recall": float(box.mr),
        "per_class": per_class,
    }

    print("=" * 80)
    print(f"整体  mAP@0.5 = {summary['map50']:.4f}   mAP@0.5:0.95 = {summary['map50_95']:.4f}   "
          f"macro P = {summary['precision']:.4f}   macro R = {summary['recall']:.4f}")
    print("=" * 80)
    print(f"{'id':>3} {'class':<24} {'P':>8} {'R':>8} {'mAP50':>8} {'mAP50-95':>9}  判定")
    print("-" * 80)

    fails: list[str] = []
    for c in per_class:
        if c["recall"] is None:
            print(f"{c['id']:>3} {c['name']:<24} {'—':>8} {'—':>8} {'—':>8} {'—':>9}  该折无样本")
            continue
        crit = c["name"] in EXIT_CRITERIA["critical_classes"]
        if crit and c["recall"] < EXIT_CRITERIA["per_class_recall_min"]:
            verdict = f"[X] 关键类召回 {c['recall']:.2f} < {EXIT_CRITERIA['per_class_recall_min']}"
            fails.append(c["name"])
        elif crit:
            verdict = "[OK]"
        else:
            verdict = "—"
        print(f"{c['id']:>3} {c['name']:<24} {c['precision']:>8.3f} {c['recall']:>8.3f} "
              f"{c['map50']:>8.3f} {c['map50_95']:>9.3f}  {verdict}")

    notes = diagnose(rows, summary)
    pdfs = [] if args.no_plot else plot_training_curves(run_dir)

    def fmt(v) -> str:
        return "—" if v is None else f"{v:.3f}"

    lines = [
        "# 训练结果报告", "",
        f"- 权重：`{weights.relative_to(REPO_ROOT).as_posix()}`",
        f"- 评测折：`{args.split}`",
        f"- 训练轮数：{len(rows) if rows else '（无 results.csv）'}",
        "",
        "## 整体指标", "",
        f"- mAP@0.5：**{summary['map50']:.4f}**",
        f"- mAP@0.5:0.95：{summary['map50_95']:.4f}",
        f"- macro Precision：{summary['precision']:.4f}",
        f"- macro Recall：{summary['recall']:.4f}",
        "",
        "## 逐类指标", "",
        "| id | 类别 | P | R | mAP@0.5 | mAP@0.5:0.95 |",
        "|---|---|---|---|---|---|",
    ]
    for c in per_class:
        lines.append(f"| {c['id']} | {c['name']} | {fmt(c['precision'])} | {fmt(c['recall'])} "
                     f"| {fmt(c['map50'])} | {fmt(c['map50_95'])} |")

    lines += ["", "## 出口条件核对", "",
              f"- [{'x' if summary['map50'] >= EXIT_CRITERIA['overall_map50_min'] else ' '}] "
              f"整体 mAP@0.5 >= {EXIT_CRITERIA['overall_map50_min']}"
              f"（实测 {summary['map50']:.4f}）"]
    for name in EXIT_CRITERIA["critical_classes"]:
        row = next((c for c in per_class if c["name"] == name), None)
        if row is None or row["recall"] is None:
            lines.append(f"- [ ] {name} Recall —（该折无样本，无法判定）")
        else:
            mark = "x" if row["recall"] >= EXIT_CRITERIA["per_class_recall_min"] else " "
            lines.append(f"- [{mark}] {name} Recall >= {EXIT_CRITERIA['per_class_recall_min']}"
                         f"（实测 {row['recall']:.3f}）")

    if fails:
        lines += ["", "## 未达标的关键类", ""] + [f"- `{n}`" for n in fails] + [
            "", "处置顺序：① 该类样本过采样 ② 提高 imgsz 到 768（需重测真机延迟）"
                " ③ 升级到 yolov8s 重训。"]

    if notes:
        lines += ["", "## 自动诊断", ""] + [f"- {n}" for n in notes]

    lines += ["", "## 曲线图与可视化", ""]
    if pdfs:
        lines += [f"- `{p}`（本脚本生成）" for p in pdfs]
        lines += ["", "重点看：val 损失是否先降后升（过拟合）；mAP 曲线何时见顶。"]
    for f in ("results.png", "confusion_matrix_normalized.png", "BoxPR_curve.png",
              "val_batch0_labels.jpg", "val_batch0_pred.jpg", "labels.jpg"):
        if (run_dir / f).exists():
            lines.append(f"- `{f}`（Ultralytics 生成）")

    report = run_dir / "eval_report.md"
    report.write_text("\n".join(lines), encoding="utf-8")

    if notes:
        print("\n自动诊断：")
        for n in notes:
            print(f"  {n}")
    if pdfs:
        print(f"\n曲线图已生成：{', '.join(pdfs)}")
    print(f"\n报告：{report.relative_to(REPO_ROOT)}")
    print("\nUltralytics 自带的可视化（终端无法显示，请用图片查看器打开）：")
    for f in ("results.png", "confusion_matrix_normalized.png", "BoxPR_curve.png",
              "val_batch0_labels.jpg", "val_batch0_pred.jpg", "labels.jpg"):
        if (run_dir / f).exists():
            print(f"  runs\\{run_dir.name}\\{f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
