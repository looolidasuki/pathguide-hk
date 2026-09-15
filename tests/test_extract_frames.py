import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from extract_frames import frame_filename, is_sharp  # noqa: E402


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
