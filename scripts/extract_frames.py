"""从视频中按固定时间间隔抽帧，并过滤模糊帧。

职责边界：本脚本只做「抽帧 + 去模糊（+ 可选去重）」，不做**按类别筛选**——
按类别选帧是 scan_video_frames.py 的事。

## 什么时候用这个、什么时候用 scan_video_frames.py

- **本脚本**：为**人工标注**准备素材。它不依赖任何模型，因此对那些零样本模型
  完全没有召回的类（实测 `stairs` 在 40 分钟香港街景里最高分 0.000）照样有效。
- **scan_video_frames.py**：让模型挑出「最像某一类」的帧。对模型认得的类很省人力，
  但模型认不出的类它一帧也选不出来——**这不是它的缺陷，是它的适用边界**。

用法：
    # 原有：按路线抽帧（素材放在 data/raw/<route>/ 下）
    python scripts/extract_frames.py --route route_A --fps 2 --blur-thresh 100

    # 新增：直接指定视频/目录，并可顺手去重
    python scripts/extract_frames.py --videos data/raw/myVideo --fps 0.1 \
        --out data/frames/label_me --dedup-threshold 6
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


def resolve_videos(specs: list[str]) -> list[Path]:
    """把「文件或目录」的混合输入展开成视频文件列表（去重、排序）。"""
    out: list[Path] = []
    for s in specs:
        p = Path(s)
        if not p.is_absolute():
            p = REPO_ROOT / p
        if p.is_dir():
            out.extend(find_videos(p))
        elif p.is_file() and p.suffix in VIDEO_EXTS:
            out.append(p)
        else:
            print(f"[WARN] 跳过（不是视频也不是含视频的目录）：{s}")
    return sorted(dict.fromkeys(out))


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
        # 用 grab() 跳过不需要的帧：素材是 59.94 fps，而我们要的是 0.1 fps，
        # 也就是 599 帧里只用 1 帧。read() 会把另外 598 帧也解码一遍。
        if not cap.grab():
            break
        if read_idx % step == 0:
            ok, frame = cap.retrieve()
            if not ok:
                read_fail += 1
            else:
                gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                if not is_sharp(gray, blur_thresh):
                    skipped_blur += 1
                else:
                    name = frame_filename(source, video_path.stem, read_idx)
                    ok_write, buf = cv2.imencode(
                        ".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
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


def dedup_dir(out_dir: Path, threshold: int) -> int:
    """对目录内已抽出的帧做 phash 去重，返回删除张数。

    手持视频里相邻采样帧常常几乎一样（尤其走路时前方景物变化很慢），
    不去重会让标注的人对着同一场景画好几遍。

    按文件名升序处理 = 按帧号先后，保留先出现的那张。
    """
    if threshold <= 0:
        return 0
    from dedup import compute_hash, is_duplicate  # 只在需要时导入

    seen: list[int] = []
    dropped = 0
    for p in sorted(out_dir.glob("*.jpg")):
        h = compute_hash(p, "phash")
        if is_duplicate(h, seen, threshold):
            p.unlink()
            dropped += 1
        else:
            seen.append(h)
    return dropped


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--route", choices=["route_A", "route_B"],
                    help="按路线抽帧（读 data/raw/<route>/）。与 --videos 二选一")
    ap.add_argument("--videos", nargs="*", default=None,
                    help="视频文件或含视频的目录；给了它就忽略 --route")
    ap.add_argument("--out", default=None,
                    help="输出根目录；默认 data/frames/<route>（--videos 模式必填）")
    ap.add_argument("--fps", type=float, default=2.0,
                    help="每秒抽取帧数。给人工标注用建议 0.1（每 10 秒 1 帧）")
    ap.add_argument("--blur-thresh", type=float, default=100.0)
    ap.add_argument("--max-frames", type=int, default=None)
    ap.add_argument("--dedup-threshold", type=int, default=0,
                    help=">0 时对抽出的帧做 phash 去重（汉明距离阈值），"
                         "走路视频建议 6")
    args = ap.parse_args()

    if args.videos:
        videos = resolve_videos(args.videos)
        if not args.out:
            print("--videos 模式必须给 --out（不知道该写到哪）")
            return 1
        out_root = Path(args.out)
        if not out_root.is_absolute():
            out_root = REPO_ROOT / out_root
    else:
        if not args.route:
            print("请给 --route，或用 --videos 指定素材。")
            return 1
        raw_route = RAW_DIR / args.route
        videos = find_videos(raw_route)
        out_root = FRAMES_DIR / args.route
        if not videos:
            print(f"未在 {raw_route} 找到视频文件。")
            return 1

    total_kept = total_blur = total_fail = total_dropped = 0
    for video in videos:
        source = video.parent.name
        out_dir = out_root / source
        kept, blur, fail = extract_one(
            video, out_dir, source, args.fps, args.blur_thresh, args.max_frames
        )
        dropped = dedup_dir(out_dir, args.dedup_threshold)
        total_kept += kept
        total_blur += blur
        total_fail += fail
        total_dropped += dropped
        print(f"{source}/{video.name}: kept={kept} blur={blur} fail={fail} "
              f"dedup_dropped={dropped}")

    print(f"\n写出 {total_kept}，模糊丢 {total_blur}，读取失败 {total_fail}，"
          f"去重又丢 {total_dropped}，最终 {total_kept - total_dropped}")
    print(f"输出目录：{out_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
