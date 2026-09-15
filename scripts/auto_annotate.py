"""三段式自动预标 —— 编排脚本。

把「图片目录 -> 可直接训练的 YOLO 标注」串成一条命令。

    python scripts\\auto_annotate.py --input data/raw/route_A/trashbin --object 垃圾桶

单物件聚焦用法（推荐先这样试）：
    python scripts\\auto_annotate.py --input data/raw/route_A/trashbin \\
        --object trashbin --focus-class street_obstacle --eval

设计说明：
- 第一段跑在**主环境**（YOLO-World + CLIP），第二段跑在 **.venv-vlm**
  （LocateAnything 需要 transformers 4.57.1，与主环境的 5.x 冲突）。
  两者通过磁盘上的 JSONL 交接，互不 import。
- 每段都幂等、可单独重跑。第二段的 VLM 结果有缓存，中断后续跑不会重复推理。
- **默认不静默采纳未经复核的框**：VLM 未判定的框进 review.csv 交人处理。
  这是刻意的保守设计——静默采纳会让未验证的框混进数据集，而失败是无声的。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PIPELINE = REPO_ROOT / "scripts" / "pipeline"
MAIN_PY = Path(sys.executable)
VLM_PY = REPO_ROOT / ".venv-vlm" / "Scripts" / "python.exe"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def child_env() -> dict[str, str]:
    """子进程环境：把第三方库的写路径全部重定向到工作区内。

    不这样做的话，transformers 会去写 ~/.cache/huggingface/modules 而失败
    （受限环境下工作区外不可写）。实测踩到过，故在编排层统一处理，
    调用者无需手动设任何环境变量。
    """
    env = os.environ.copy()
    redirects = {
        "HF_HOME": REPO_ROOT / ".hf",
        "HF_MODULES_CACHE": REPO_ROOT / ".hf" / "modules",
        "HF_HUB_CACHE": Path.home() / ".cache" / "huggingface" / "hub",  # 已下好的模型在这里
        "TORCHINDUCTOR_CACHE_DIR": REPO_ROOT / ".tmp" / "inductor",
        "TMP": REPO_ROOT / ".tmp",
        "TEMP": REPO_ROOT / ".tmp",
        "YOLO_CONFIG_DIR": REPO_ROOT / ".ultralytics-config",
        "MPLCONFIGDIR": REPO_ROOT / ".mpl-cache",
        "YOLO_AUTOINSTALL": "false",
    }
    for k, v in redirects.items():
        v = Path(v)
        if k not in ("HF_HUB_CACHE", "YOLO_AUTOINSTALL"):
            v.mkdir(parents=True, exist_ok=True)
        env[k] = str(v)
    return env


def banner(step: str, title: str) -> None:
    print(f"\n{'=' * 70}\n[{step}] {title}\n{'=' * 70}", flush=True)


def count_images(root: Path) -> int:
    if not root.exists():
        return 0
    return sum(1 for p in root.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_EXTS)


def run(cmd: list[str], title: str) -> int:
    print(f"$ {' '.join(str(c) for c in cmd)}\n", flush=True)
    proc = subprocess.run([str(c) for c in cmd], cwd=str(REPO_ROOT), env=child_env())
    if proc.returncode != 0:
        print(f"\n[失败] {title} 退出码 {proc.returncode}")
    return proc.returncode


def main() -> int:
    ap = argparse.ArgumentParser(
        description="三段式自动预标：图片目录 -> YOLO 标注（无需手画框）")
    ap.add_argument("--input", required=True,
                    help="输入图像目录（递归）。建议按来源点位分子目录，"
                         "子目录名会成为分组划分的依据")
    ap.add_argument("--object", required=True, help="物件名，用于输出目录与报告标题")
    ap.add_argument("--focus-class", default=None,
                    help="聚焦的类别英文名（如 street_obstacle）。会给出一句话结论")
    ap.add_argument("--single-class", action="store_true",
                    help="单物件模式：只保留 --focus-class 这一类，标签索引重映射为 0，"
                         "并生成 datasets/<object>.yaml。"
                         "适合「单独训一个物件」——垃圾桶不该塞进 16 类检测器"
                         "当 street_obstacle，那会让它与护柱、路障争同一类。")
    ap.add_argument("--work", default=None,
                    help="中间产物根目录，默认 data/auto/<object>")
    ap.add_argument("--dataset", default=None,
                    help="若指定，第三段直接写入该 YOLO 数据集目录（images/ 与 labels/）")
    # 各段参数透传
    ap.add_argument("--weights", default="yolov8s-world.pt")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=0.15,
                    help="第一段出框门槛（宜低，由后两段筛）")
    ap.add_argument("--min-conf", type=float, default=0.35,
                    help="第三段采纳门槛")
    ap.add_argument("--trust-above", type=float, default=1.01,
                    help="第二段跳过 VLM 验证的置信度上限；默认 1.01 = 全量验证")
    ap.add_argument("--no-refine", dest="refine", action="store_false", default=True,
                    help="关闭 SAM 修框")
    ap.add_argument("--limit", type=int, default=None, help="只处理前 N 张（试跑）")
    ap.add_argument("--eval", action="store_true", help="最后自动跑效果评估与叠加图")
    ap.add_argument("--eval-limit", type=int, default=None, help="叠加图最多生成几张")
    ap.add_argument("--skip-stage1", action="store_true")
    ap.add_argument("--skip-stage2", action="store_true")
    args = ap.parse_args()

    t_all = time.time()
    img_root = Path(args.input)
    img_root = img_root if img_root.is_absolute() else (REPO_ROOT / img_root)
    if not img_root.exists():
        print(f"输入目录不存在：{img_root}")
        return 1
    n_img = count_images(img_root)
    if n_img == 0:
        print(f"未在 {img_root} 找到图像。")
        return 1

    work = Path(args.work) if args.work else (REPO_ROOT / "data" / "auto" / args.object)
    work = work if work.is_absolute() else (REPO_ROOT / work)
    prop_dir = work / "proposals"
    ver_dir = work / "verified"
    final_dir = work / "final"

    print(f"物件    : {args.object}")
    print(f"输入    : {img_root.relative_to(REPO_ROOT) if img_root.is_relative_to(REPO_ROOT) else img_root}"
          f"  （{n_img} 张）")
    print(f"中间产物: {work.relative_to(REPO_ROOT)}")
    print(f"主环境  : {MAIN_PY}")
    print(f"VLM 环境: {VLM_PY}  {'[就绪]' if VLM_PY.exists() else '[缺失!]'}")

    if not VLM_PY.exists():
        print(f"\n[错误] 未找到 VLM 环境：{VLM_PY}")
        print("第二段需要独立的 .venv-vlm（transformers 4.57.1 与主环境冲突）。")
        print("重建方式见 scripts/env_setup.py 注释与 docs/ 下的执行记录。")
        return 1

    # ---------------- 第一段 ----------------
    if not args.skip_stage1:
        banner("1/4", "第一段 · YOLO-World 出框")
        cmd = [MAIN_PY, PIPELINE / "stage1_propose.py",
               "--images", str(img_root), "--out", str(prop_dir),
               "--weights", args.weights, "--imgsz", str(args.imgsz),
               "--conf", str(args.conf)]
        if args.limit:
            cmd += ["--limit", str(args.limit)]
        if run(cmd, "第一段") != 0:
            return 1
    else:
        banner("1/4", "第一段 · 已跳过")

    if not (prop_dir / "proposals.jsonl").exists():
        print(f"缺少 {prop_dir / 'proposals.jsonl'}")
        return 1

    # ---------------- 第二段 ----------------
    if not args.skip_stage2:
        banner("2/4", "第二段 · SAM 修框 + LocateAnything 裁剪验证")
        cmd = [VLM_PY, PIPELINE / "stage2_verify.py",
               "--proposals", str(prop_dir), "--out", str(ver_dir),
               "--trust-above", str(args.trust_above)]
        if args.limit:
            cmd += ["--limit", str(args.limit)]
        if not args.refine:
            cmd.append("--no-refine")
        if run(cmd, "第二段") != 0:
            return 1
    else:
        banner("2/4", "第二段 · 已跳过")

    if not (ver_dir / "verified.jsonl").exists():
        print(f"缺少 {ver_dir / 'verified.jsonl'}")
        return 1

    # ---------------- 第三段 ----------------
    banner("3/4", "第三段 · 冲突消解 + 汇出标签与复核清单")
    cmd = [MAIN_PY, PIPELINE / "stage3_arbitrate.py",
           "--verified", str(ver_dir), "--images", str(img_root),
           "--out", str(final_dir), "--min-conf", str(args.min_conf)]
    if args.dataset:
        cmd += ["--dataset", args.dataset]
    if args.single_class:
        if not args.focus_class:
            print("[错误] --single-class 需要同时指定 --focus-class")
            return 1
        cmd += ["--single-class", args.focus_class, "--dataset-name", args.object]
    if run(cmd, "第三段") != 0:
        return 1

    # ---------------- 评估 ----------------
    if args.eval:
        banner("4/4", "效果评估 + 叠加图")
        cmd = [MAIN_PY, REPO_ROOT / "scripts" / "eval_object.py",
               "--name", args.object, "--raw", str(img_root),
               "--proposals", str(prop_dir), "--verified", str(ver_dir),
               "--class", args.focus_class or "", "--overlay"]
        if args.eval_limit:
            cmd += ["--overlay-limit", str(args.eval_limit)]
        run(cmd, "评估")
    else:
        banner("4/4", "效果评估 · 已跳过（加 --eval 开启）")

    # ---------------- 汇总 ----------------
    elapsed = time.time() - t_all
    s3 = final_dir / "stage3_report.json"
    print(f"\n{'=' * 70}\n完成，总耗时 {elapsed / 60:.1f} 分钟\n{'=' * 70}")
    if s3.exists():
        d = json.loads(s3.read_text(encoding="utf-8"))
        print(f"输入图像      : {d['images']}")
        print(f"候选框        : {d['input_boxes']}")
        print(f"采纳          : {d['accepted']}")
        print(f"需人工复核    : {d['review_items']}")
        print(f"（其中 面积异常 {d['review_huge']}，VLM未判定 {d['review_unknown_verdict']}，"
              f"跨类合并 {d['merged_cross_class']}）")
        print(f"\n产出：")
        print(f"  最终标签    : {(final_dir / 'labels').relative_to(REPO_ROOT)}")
        print(f"  人工复核清单: {(final_dir / 'review.csv').relative_to(REPO_ROOT)}")
        if d.get("dataset"):
            print(f"  训练数据集  : {d['dataset']['root']}  "
                  f"（{d['dataset']['images_copied']} 张，可直接训练）")
        print(f"\n{'─' * 70}")
        print("下一步：")
        if d.get("dataset"):
            print("  python scripts\\make_manifest.py")
            print("  python scripts\\split_dataset.py --seed 42")
            print("  python scripts\\check_labels.py")
            print("  python scripts\\run_pipeline.py --skip-generate --epochs 100 --workers 4")
        else:
            print("  用 --dataset <目录> 重跑第三段即可直接写入训练数据集结构")
        print("  人工只需处理 review.csv 里那部分（Accept/Reject，不必画框）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
