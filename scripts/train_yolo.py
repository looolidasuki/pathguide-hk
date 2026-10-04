"""训练一个 YOLO 检测模型（本项目通用入口）。

## 为什么单独一个脚本

训练参数里有一堆**踩过坑才定下来的**默认值，散落在各处调用会各自踩一遍：

- `workers=0`（默认）：DataLoader 的多进程依赖命名管道，**受限沙箱会拒绝**
  （`ThreadPool` 同理，`env_setup` 里已有对应补丁）。写 4 会直接
  `PermissionError: [WinError 5]`。
  ★ 2026-10-02 修正：这**不是环境本身的限制，是沙箱模式造成的**。
  在放宽文件/进程访问的模式下 `--workers 8` 可用，而且**快 2.5 倍**
  （poc5 上实测 60.6 秒/轮 vs 152.7 秒/轮）——因为 workers=0 时 GPU 大部分时间在等数据。
  所以做多骨干对比这类批量训练时，应显式 `--workers 8` 并放宽访问；
  单次小实验用默认 0 即可。默认仍保持 0，保证任何模式下都能跑起来。
- `seed=42` 固定：不固定的话，两次实验的差异分不清是改动带来的还是随机初始化的。
- `pretrained=True`（默认从 `yolo11n.pt` 起步）：这是「传统预训练」在本项目的落点，
  改成 from scratch 对比时用 `--scratch`。

用法：
    # 冷启动数据集（COCO 自动标注）
    python scripts/train_yolo.py --data data/dataset_person_poc/dataset.yaml --name person_poc

    # 正式数据集
    python scripts/train_yolo.py --data data/dataset/_split/pathguide.yaml \
        --name pg_full --epochs 100

    # 对照：不用预训练权重
    python scripts/train_yolo.py --data <yaml> --name from_scratch --scratch
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import env_setup  # noqa: E402,F401  必须在 ultralytics 之前


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, help="数据集 yaml")
    ap.add_argument("--name", required=True, help="本次实验名（决定 runs/<name>）")
    ap.add_argument("--model", default="yolo11n.pt")
    ap.add_argument("--scratch", action="store_true",
                    help="不用预训练权重（用同名的 .yaml 从头训）")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--imgsz", type=int, default=416,
                    help="默认 416：与部署端一致，也是本项目训练时用的尺寸")
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--patience", type=int, default=30)
    ap.add_argument("--workers", type=int, default=0,
                    help="取数进程数。**默认 0**：本环境的多进程取数曾被沙箱拒绝"
                         "（命名管道不允许），所以默认保持能跑的值。"
                         "但实测 0 会让 GPU 大部分时间在等数据——"
                         "做多骨干对比时若能用 >0，总耗时能降一个量级。"
                         "用 --workers 显式开启前请先跑一次短训练确认不报错。")
    ap.add_argument("--lr0", type=float, default=None,
                    help="初始学习率。**第二阶段微调必须调小**（如 0.001）："
                         "默认 0.01 是为从头训设计的，拿来微调会把上一版学到的"
                         "其它类冲掉——而那种损失在本项目的验证集上**看不见**"
                         "（val 里没有那些类的实例），所以只能靠低学习率预防。")
    ap.add_argument("--freeze", type=int, default=None,
                    help="冻结前 N 层（如 10 = 冻结骨干）。比低学习率更强地保住既有特征，"
                         "代价是新类学得慢。")
    args = ap.parse_args()

    from ultralytics import YOLO

    weights = args.model
    if args.scratch:
        weights = args.model.replace(".pt", ".yaml")
    model = YOLO(weights)
    print(f"起点权重：{weights}"
          f"{'（scratch）' if args.scratch else '（预训练）'}")

    extra: dict = {}
    if args.lr0 is not None:
        extra["lr0"] = args.lr0
    if args.freeze is not None:
        extra["freeze"] = args.freeze
    if extra:
        print(f"微调参数：{extra}")

    model.train(
        data=args.data,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        seed=args.seed,
        patience=args.patience,
        workers=args.workers,   # 默认 0：本环境多进程取数曾被沙箱拒绝（见 --workers 说明）
        project=str(REPO_ROOT / "runs"),
        name=args.name,
        exist_ok=True,
        plots=False,        # 无头环境，画图没意义还拖时间
        val=True,
        verbose=False,
        **extra,
    )

    metrics = model.val(data=args.data, imgsz=args.imgsz, workers=0, verbose=False)
    print("\n=== 验证结果 ===")
    print(f"  mAP50     {metrics.box.map50:.4f}")
    print(f"  mAP50-95  {metrics.box.map:.4f}")
    print(f"  precision {metrics.box.mp:.4f}")
    print(f"  recall    {metrics.box.mr:.4f}")
    print(f"\n权重：runs/{args.name}/weights/best.pt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
