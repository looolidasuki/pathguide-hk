import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from extract_frames import (  # noqa: E402
    dedup_dir,
    frame_filename,
    is_sharp,
    resolve_videos,
)


def test_frame_filename_is_zero_padded_and_ascii():
    name = frame_filename("20260920_tsk_footbridge", "VID_001", 7)
    assert name == "20260920_tsk_footbridge_VID_001_000007.jpg"
    assert name.isascii()


def test_frame_filename_pads_beyond_six_digits():
    name = frame_filename("s", "v", 1234567)
    assert name.endswith("_1234567.jpg")


def test_is_sharp_rejects_flat_image():
    flat = np.full((100, 100), 128, dtype=np.uint8)
    assert is_sharp(flat, threshold=100.0) is False


def test_is_sharp_accepts_high_contrast_noise():
    rng = np.random.default_rng(0)
    noisy = rng.integers(0, 256, size=(100, 100), dtype=np.uint8)
    assert is_sharp(noisy, threshold=100.0) is True


def test_is_sharp_threshold_is_exclusive():
    flat = np.full((50, 50), 200, dtype=np.uint8)
    assert is_sharp(flat, threshold=0.0) is False


# ---------------------------------------------------------------- 素材发现

def _textured(path: Path, seed: int) -> None:
    """有纹理的测试图。

    纯色图会让 phash 退化：实测任何非黑纯色都得到同一个哈希
    （`8000000000000000`），于是「两张不同颜色的图」会被判成重复。
    """
    from PIL import Image

    rng = np.random.default_rng(seed)
    Image.fromarray(rng.integers(0, 255, (64, 64, 3), dtype=np.uint8)).save(path)


def test_resolve_videos_accepts_files_and_dirs(tmp_path):
    v1, v2 = tmp_path / "a.mp4", tmp_path / "b.mp4"
    v1.write_bytes(b"x")
    v2.write_bytes(b"x")
    got = resolve_videos([str(v1), str(tmp_path)])
    assert got == [v1, v2], "同一个视频既给文件又给目录时只能算一次"


def test_resolve_videos_skips_non_video(tmp_path, capsys):
    (tmp_path / "notes.txt").write_text("hi", encoding="utf-8")
    assert resolve_videos([str(tmp_path / "notes.txt")]) == []
    assert "跳过" in capsys.readouterr().out


# ---------------------------------------------------------------- 去重

def test_dedup_dir_removes_duplicates_and_keeps_the_earliest(tmp_path):
    _textured(tmp_path / "s_v_000010.jpg", seed=1)
    _textured(tmp_path / "s_v_000020.jpg", seed=1)     # 与上一张相同
    _textured(tmp_path / "s_v_000030.jpg", seed=2)     # 不同

    dropped = dedup_dir(tmp_path, threshold=6)

    assert dropped == 1
    assert (tmp_path / "s_v_000010.jpg").exists(), "按帧号保留先出现的那张"
    assert not (tmp_path / "s_v_000020.jpg").exists()
    assert (tmp_path / "s_v_000030.jpg").exists()


def test_dedup_dir_threshold_zero_is_noop(tmp_path):
    _textured(tmp_path / "a.jpg", seed=1)
    _textured(tmp_path / "b.jpg", seed=1)
    assert dedup_dir(tmp_path, threshold=0) == 0
    assert (tmp_path / "a.jpg").exists() and (tmp_path / "b.jpg").exists()


def test_dedup_dir_on_empty_dir(tmp_path):
    assert dedup_dir(tmp_path, threshold=6) == 0
