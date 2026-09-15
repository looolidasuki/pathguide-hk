"""从视频中按固定时间间隔抽帧，并过滤模糊帧。

职责边界：本脚本只做「抽帧 + 去模糊」，不做去重——去重由 dedup.py 负责。

用法：
    python scripts/extract_frames.py --route route_A --fps 2 --blur-thresh 100
"""
from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
FRAMES_DIR = REPO_ROOT / "data" / "frames"
RAW_DIR = REPO_ROOT / "data" / "raw"

VIDEO_EXTS = {".mp4", ".mov", ".avi", ".mkv", ".MP4", ".MOV", ".AVI", ".MKV"}


def frame_filename(source: str, video_stem: str, frame_idx: int) -> str:
    """生成抽帧文件名：<source>_<video>_<帧号>.jpg（帧号补零到 6 位）。"""
    return f"{source}_{video_stem}_{frame_idx:06d}.jpg"


def is_sharp(gray: np.ndarray, threshold: float) -> bool:
    """拉普拉斯方差 > threshold 视为清晰。threshold 为严格下界。"""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var()) > threshold


def find_videos(raw_route_dir: Path) -> list[Path]:
    if not raw_route_dir.exists():
        return []
    return sorted(
        p for p in raw_route_dir.rglob("*") if p.is_file() and p.suffix in VIDEO_EXTS
    )


def extract_one(
    video_path: Path,
    out_dir: Path,
    source: str,
    fps: float,
    blur_thresh: float,
    max_frames: int | None,
) -> tuple[int, int, int]:
    """返回 (kept, skipped_blur, skipped_read_fail)。"""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"  [WARN] 无法打开视频：{video_path}")
        return 0, 0, 0

    video_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    if video_fps <= 0:
        video_fps = 30.0
    step = max(1, int(round(video_fps / fps)))

    out_dir.mkdir(parents=True, exist_ok=True)
    kept = skipped_blur = read_fail = 0
    read_idx = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if read_idx % step == 0:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            if not is_sharp(gray, blur_thresh):
                skipped_blur += 1
            else:
                name = frame_filename(source, video_path.stem, read_idx)
                ok_write, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                if not ok_write:
                    read_fail += 1
                else:
                    buf.tofile(str(out_dir / name))
                    kept += 1
                    if max_frames is not None and kept >= max_frames:
                        cap.release()
                        return kept, skipped_blur, read_fail
        read_idx += 1

    cap.release()
    return kept, skipped_blur, read_fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--route", required=True, choices=["route_A", "route_B"])
    ap.add_argument("--fps", type=float, default=2.0, help="每秒抽取帧数")
    ap.add_argument("--blur-thresh", type=float, default=100.0)
    ap.add_argument("--max-frames", type=int, default=None)
    args = ap.parse_args()

    raw_route = RAW_DIR / args.route
    videos = find_videos(raw_route)
    if not videos:
        print(f"未在 {raw_route} 找到视频文件。")
        return 1

    total_kept = total_blur = total_fail = 0
    for video in videos:
        source = video.parent.name
        out_dir = FRAMES_DIR / args.route / source
        kept, blur, fail = extract_one(
            video, out_dir, source, args.fps, args.blur_thresh, args.max_frames
        )
        total_kept += kept
        total_blur += blur
        total_fail += fail
        print(f"{source}/{video.name}: kept={kept} blur={blur} fail={fail}")

    print(f"\nkept={total_kept} skipped_blur={total_blur} skipped_read_fail={total_fail}")
    print(f"输出目录：{FRAMES_DIR / args.route}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
