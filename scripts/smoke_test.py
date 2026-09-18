"""Windows + CUDA 冒烟测试：少量图像、2 epoch，验证训练链路可用。

为什么需要它：Windows 上 Ultralytics 最常见的失败是 DataLoader 多进程与 CUDA 初始化
问题，往往在长训练跑到一半才暴露。本脚本用约 2 分钟把这类问题提前探明。

用法：
    python scripts/smoke_test.py
"""
from __future__ import annotations

import random
import shutil
import sys
from pathlib import Path

import env_setup  # noqa: F401  必须在 ultralytics 之前导入

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
IMAGES_DIR = DATASET_DIR / "images"
LABELS_DIR = DATASET_DIR / "labels"
SMOKE_DIR = REPO_ROOT / "data" / "_smoke"
SMOKE_YAML = REPO_ROOT / "datasets" / "smoke.yaml"
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
N_SAMPLES = 20
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"}


def n_classes() -> int:
    """类别数从 classes.json 读取——不硬编码，否则类别表一改这里就静默失真。"""
    import json

    with CLASSES_PATH.open(encoding="utf-8") as f:
        return len(json.load(f)["classes"])


def collect_labelled_pairs() -> list[tuple[Path, Path]]:
    pairs: list[tuple[Path, Path]] = []
    if not IMAGES_DIR.exists():
        return pairs
    for img in IMAGES_DIR.rglob("*"):
        if not img.is_file() or img.suffix not in IMAGE_EXTS:
            continue
        # 标签**镜像** images 的子目录结构：images/<源>/a.jpg -> labels/<源>/a.txt
        label = (LABELS_DIR / img.relative_to(IMAGES_DIR)).with_suffix(".txt")
        if label.exists():
            pairs.append((img, label))
    return pairs


def build_smoke_dataset(pairs: list[tuple[Path, Path]], seed: int = 42) -> Path:
    if SMOKE_DIR.exists():
        shutil.rmtree(SMOKE_DIR)
    (SMOKE_DIR / "images").mkdir(parents=True)
    (SMOKE_DIR / "labels").mkdir(parents=True)

    rng = random.Random(seed)
    sample = rng.sample(pairs, min(N_SAMPLES, len(pairs)))
    n_val = max(1, len(sample) // 5)
    for i, (img, label) in enumerate(sample):
        sub = "val" if i < n_val else "train"
        shutil.copy2(img, SMOKE_DIR / "images" / f"{sub}_{img.name}")
        shutil.copy2(label, SMOKE_DIR / "labels" / f"{sub}_{img.stem}.txt")

    nc = n_classes()
    SMOKE_YAML.write_text(
        "# 冒烟测试用，自动生成，勿手工编辑\n"
        f"path: {SMOKE_DIR.as_posix()}\n"
        "train: images\n"
        "val: images\n\n"
        f"nc: {nc}\n"
        "names:\n" + "\n".join(f"  {i}: c{i}" for i in range(nc)) + "\n",
        encoding="utf-8",
    )
    return SMOKE_YAML


def main() -> int:
    try:
        import torch
    except ImportError:
        print("torch 未安装，请先安装依赖。")
        return 1

    if not torch.cuda.is_available():
        print("CUDA 不可用。请先修复 GPU 环境再运行冒烟测试。")
        return 1

    props = torch.cuda.get_device_properties(torch.cuda.current_device())
    vram_gb = props.total_memory / (1024 ** 3)
    print(f"GPU: {props.name} ({vram_gb:.1f} GB, sm_{props.major}{props.minor})")

    pairs = collect_labelled_pairs()
    if len(pairs) < 5:
        print(f"已标注图像不足（找到 {len(pairs)} 对），无法构成冒烟集。")
        print("请先生成合成数据或完成至少 5 张图的标注：")
        print("  python scripts/gen_synthetic.py --per-class 4")
        return 1

    yaml_path = build_smoke_dataset(pairs)
    print(f"冒烟集已构建：{SMOKE_DIR}（{min(N_SAMPLES, len(pairs))} 张）")

    from ultralytics import YOLO

    batch = 8 if vram_gb >= 8 else 4
    model = YOLO("yolov8n.pt")
    results = model.train(
        data=str(yaml_path),
        epochs=2,
        imgsz=320,
        batch=batch,
        workers=2,
        project=str(REPO_ROOT / "runs"),
        name="smoke",
        exist_ok=True,
        verbose=True,
        plots=False,
    )

    save_dir = Path(getattr(results, "save_dir", REPO_ROOT / "runs" / "smoke"))
    best = save_dir / "weights" / "best.pt"
    print(f"\nsave_dir: {save_dir}")
    print(f"best.pt 存在: {best.exists()}")
    if not best.exists():
        print("冒烟测试失败：未产出权重文件。")
        return 1

    print("冒烟测试通过。训练链路（CUDA + DataLoader + 保存）均可用。")
    print("提示：若出现卡死，请把 workers 改为 0 后重跑本脚本验证。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
