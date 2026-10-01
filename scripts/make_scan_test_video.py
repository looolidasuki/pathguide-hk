"""合成一段「已知答案」的测试视频，用来端到端验证视频扫描流水线。

## 为什么要合成而不是等真视频

扫描流水线的核心承诺是「**只留有目标的帧**」。这句话对不对，只有在
「哪些帧真的有目标」已知的情况下才能判定。真实素材里我们并不知道答案，
拿它验证只能看出「跑通了」，看不出「筛对了」。

所以这里造一段答案已知的视频：按 30 帧一段切成若干段，
交替使用「空街背景」与「背景上贴一个垃圾桶」。

## 已知答案

    段 | 帧号范围 | 内容        | 采样帧(step=30) | 期望
    ---+----------+-------------+-----------------+------------------
     0 |   0- 29  | 空街        |   0             | 丢
     1 |  30- 59  | 空街        |  30             | 丢
     2 |  60- 89  | 贴 bin (1)  |  60             | 留
     3 |  90-119  | 贴 bin (1)  |  90             | 留后被去重丢掉（与上一段逐像素相同）
     4 | 120-149  | 贴 bin (16) | 120             | 留（与前面不同，能过 phash）
     5 | 150-179  | 空街        | 150             | 丢
     6 | 180-209  | 贴 bin (22) | 210? -> 见下   | 留

    期望结果：decoded=210, sampled=7, kept=4, dedup_dropped=1, 最终 3 张

用法：
    python scripts/make_scan_test_video.py            # 写到 .tmp/scan_test.mp4
"""
from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
BG_DIR = REPO_ROOT / "data" / "probe" / "streetview"
BIN_DIR = REPO_ROOT / "data" / "dataset" / "images" / "trashbin"

# 每段 30 帧；--sample-fps 1 时 step=30，于是每段恰好被采样一次
SEG_FRAMES = 30
SEGMENTS = [
    ("empty", None),
    ("empty", None),
    ("bin", "bin (1).jpg"),
    ("bin", "bin (1).jpg"),   # 与上一段逐像素相同 -> 应被去重
    ("bin", "bin (16).jpg"),
    ("empty", None),
    ("bin", "bin (22).jpg"),
]


def make_background(kind: str, size: tuple[int, int], seed: int,
                    bgs: list[Path]) -> np.ndarray:
    """背景图。

    `noise`（默认）：随机噪声，**明确不含任何目标**，且拉普拉斯方差很高、
    能过清晰度门槛。用它「空段」才是真空的，从而能验证筛子真的在筛。
    `street`：真实街景照片——更真实，但**它自己就含有人行道上的各种东西**，
    每一帧都会有命中，于是测不出筛选行为（这个坑我踩过一次）。
    """
    w, h = size
    if kind == "street" and bgs:
        img = Image.open(bgs[seed % len(bgs)]).convert("RGB")
        return cv2.resize(np.asarray(img)[:, :, ::-1], size,
                          interpolation=cv2.INTER_AREA)
    rng = np.random.default_rng(seed)
    return rng.integers(0, 255, (h, w, 3), dtype=np.uint8)


def build_frame(size: tuple[int, int], background: np.ndarray,
                bin_name: str | None) -> np.ndarray:
    """背景 + 可选的垃圾桶贴图。返回 BGR 帧。

    `bin_name` 为 None 时返回纯背景——这就是「这一帧没有目标」的定义。
    """
    frame = background.copy()
    if bin_name is None:
        return frame
    h, w = size[1], size[0]
    bgr = np.asarray(Image.open(BIN_DIR / bin_name).convert("RGB"))[:, :, ::-1]
    # 贴到画面中下部、约占半个高度：太小了零样本模型认不出，
    # 那测的就不是流水线而是模型的极限了。
    target_h = int(h * 0.5)
    scale = target_h / bgr.shape[0]
    target_w = max(1, int(bgr.shape[1] * scale))
    bgr = cv2.resize(bgr, (target_w, target_h), interpolation=cv2.INTER_AREA)
    x0 = (w - target_w) // 2
    y0 = int(h * 0.45)
    y0 = min(y0, h - target_h)
    frame[y0:y0 + target_h, x0:x0 + target_w] = bgr
    return frame


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO_ROOT / ".tmp" / "scan_test.mp4"))
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--width", type=int, default=960)
    ap.add_argument("--height", type=int, default=540)
    ap.add_argument("--background", default="noise", choices=["noise", "street"],
                    help="noise=明确无目标（默认）; street=真实街景（含杂物，测不出筛选）")
    args = ap.parse_args()

    bgs = sorted(BG_DIR.glob("*.jpg"))
    if not bgs:
        print(f"找不到背景图：{BG_DIR}")
        return 1

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    size = (args.width, args.height)
    writer = cv2.VideoWriter(str(out_path),
                             cv2.VideoWriter_fourcc(*"mp4v"),
                             args.fps, size)
    if not writer.isOpened():
        print("无法创建输出视频（缺 mp4v 编码器？）")
        return 1

    total = 0
    for seg_idx, (kind, bin_name) in enumerate(SEGMENTS):
        # 每段换一张背景，模拟镜头在移动
        bg = make_background(args.background, size, seg_idx, bgs)
        frame = build_frame(size, bg, bin_name)
        for _ in range(SEG_FRAMES):
            writer.write(frame)
            total += 1
    writer.release()

    print(f"已生成 {out_path}  ({total} 帧, {args.fps}fps, {size[0]}x{size[1]})")
    print(f"  段数 {len(SEGMENTS)}，每段 {SEG_FRAMES} 帧")
    print("  期望（--sample-fps 1）：sampled=%d kept=4 dedup_dropped=1 最终 3 张"
          % len(SEGMENTS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

