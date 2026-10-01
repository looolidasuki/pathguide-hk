"""联络表：把一目录的图拼成几页，供人工快速筛选。

它解决的问题是「在几百张图里找出该画框的那几十张」——这一步比画框本身更耗时。
所以这里断言的核心是：**页数、每页张数、以及缩略图真的能看**，
而不是像素级的排版细节。
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from make_contact_sheet import build_sheets  # noqa: E402


def _img(path: Path, seed: int = 0, size: tuple[int, int] = (160, 90)) -> Path:
    import numpy as np
    from PIL import Image

    rng = np.random.default_rng(seed)
    Image.fromarray(rng.integers(0, 255, (size[1], size[0], 3), dtype=np.uint8)).save(path)
    return path


def test_empty_input_makes_no_sheet(tmp_path):
    assert build_sheets([], tmp_path / "out") == []


def test_page_count_follows_per_sheet(tmp_path):
    imgs = [_img(tmp_path / f"f{i:03d}.jpg", i) for i in range(7)]
    made = build_sheets(imgs, tmp_path / "out", cols=2, per_sheet=3)
    assert len(made) == 3          # 3 + 3 + 1
    assert all(p.exists() for p in made)


def test_sheet_is_wide_enough_for_the_grid(tmp_path):
    imgs = [_img(tmp_path / f"f{i}.jpg", i) for i in range(4)]
    made = build_sheets(imgs, tmp_path / "out", cols=2, thumb=200, per_sheet=4)
    from PIL import Image

    with Image.open(made[0]) as im:
        assert im.width == 400                      # cols * thumb
        assert im.height > 200 * 9 / 16 * 2 - 1     # 两行 + 标签条


def test_broken_image_does_not_abort_the_sheet(tmp_path):
    """一张坏图不能让整页生成失败——否则 200 张素材里有一张损坏就白跑。"""
    good = _img(tmp_path / "ok.jpg", 1)
    bad = tmp_path / "broken.jpg"
    bad.write_bytes(b"not a jpeg")
    made = build_sheets([good, bad], tmp_path / "out", cols=2, per_sheet=2)
    assert len(made) == 1 and made[0].exists()


def test_thumbnail_keeps_aspect_ratio(tmp_path):
    """缩略图必须等比缩放——压扁了就看不出那是不是楼梯。

    测法：用**亮色**素材（背景是深灰 24，能区分开），在联络表里数出
    被贴上的那张图占了多少行，再和等比缩放应有的高度比。
    只比较「单元格高度」是不够的：拉伸填满和等比缩放都可能得到同样的单元格高度。
    """
    import numpy as np
    from PIL import Image

    thumb, label_h = 200, 26
    cell_h = thumb * 9 // 16 + label_h

    wide = tmp_path / "wide.jpg"
    Image.fromarray(np.full((90, 320, 3), 255, dtype=np.uint8)).save(wide)
    made = build_sheets([wide], tmp_path / "out", cols=1, thumb=thumb, per_sheet=1)

    with Image.open(made[0]) as sheet:
        assert sheet.height == cell_h
        a = np.asarray(sheet.convert("L"))
        # 只看图片区（排除底部标签条，那里有亮色文字会干扰）
        body = a[: cell_h - label_h]
        bright_rows = int((body.max(axis=1) > 200).sum())

    expected = round(thumb * 90 / 320)          # 320x90 等比缩到宽 200 -> 高 56
    assert abs(bright_rows - expected) <= 2, (
        f"贴上的图占 {bright_rows} 行，等比缩放应为 {expected} 行——"
        f"多出来说明被拉伸了")
