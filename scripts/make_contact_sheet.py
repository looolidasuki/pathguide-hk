"""把一个目录里的图拼成「联络表」（contact sheet），便于快速人工筛选。

## 为什么需要它

人工标注真正的瓶颈不是画框，而是**在几百张图里找出该画框的那几十张**。
逐张双击打开、看一眼、关掉，200 张就是二十分钟，而且很容易看漏。

联络表把 24 张缩略图拼成一页、每张下面带文件名：
先横扫几页、圈出「有楼梯的那几帧」，再只打开那几张精标。同样一批素材，
筛选时间从几十分钟降到几分钟。

（这是摄影行业的传统做法，也是标注工作里最被低估的一步。）

用法：
    python scripts/make_contact_sheet.py --images data/frames/label_me/myVideo
    python scripts/make_contact_sheet.py --images <dir> --cols 4 --thumb 480 --out <dir>
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parents[1]
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def load_font(size: int) -> ImageFont.ImageFont:
    """尽量用能显示中文的字体；取不到就退回默认（只影响标题美观）。"""
    for name in ("msyh.ttc", "simhei.ttf", "arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def build_sheets(
    images: list[Path],
    out_dir: Path,
    cols: int = 4,
    thumb: int = 480,
    label_h: int = 26,
    per_sheet: int | None = None,
    quality: int = 85,
) -> list[Path]:
    """把 images 拼成若干页，返回生成的文件列表。

    `per_sheet` 不指定时按 `cols * 6` 算（每页 6 行），这是「一屏能看完」的密度。
    """
    if not images:
        return []
    per = per_sheet or cols * 6
    out_dir.mkdir(parents=True, exist_ok=True)
    font = load_font(max(12, label_h - 12))
    made: list[Path] = []

    for page, start in enumerate(range(0, len(images), per), start=1):
        chunk = images[start:start + per]
        rows = (len(chunk) + cols - 1) // cols
        cell_w, cell_h = thumb, int(thumb * 9 / 16) + label_h   # 16:9 常见于视频帧
        sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), (24, 24, 24))
        draw = ImageDraw.Draw(sheet)

        for i, path in enumerate(chunk):
            r, c = divmod(i, cols)
            x, y = c * cell_w, r * cell_h
            try:
                with Image.open(path) as im:
                    im = im.convert("RGB")
                    # 等比缩放到单元格内并居中（留 2px 边距）
                    im.thumbnail((cell_w - 4, cell_h - label_h - 4))
                    sheet.paste(im, (x + (cell_w - im.width) // 2, y + 2))
            except Exception:
                draw.rectangle([x + 2, y + 2, x + cell_w - 2, y + cell_h - label_h - 2],
                               outline=(120, 40, 40))
            draw.text((x + 4, y + cell_h - label_h + 4), path.name[:34],
                      fill=(220, 220, 220), font=font)

        out = out_dir / f"sheet_{page:02d}.jpg"
        sheet.save(out, quality=quality)
        made.append(out)
    return made


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True, help="图像目录")
    ap.add_argument("--out", default=None, help="输出目录；默认 <images>/_sheets")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--thumb", type=int, default=480, help="每个缩略图宽度（像素）")
    ap.add_argument("--per-sheet", type=int, default=None,
                    help="每页张数；默认 cols*6")
    args = ap.parse_args()

    root = Path(args.images)
    if not root.is_absolute():
        root = REPO_ROOT / root
    images = sorted(p for p in root.rglob("*")
                    if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
    if not images:
        print(f"没有图像：{root}")
        return 1

    out_dir = Path(args.out) if args.out else root / "_sheets"
    if not out_dir.is_absolute():
        out_dir = REPO_ROOT / out_dir

    made = build_sheets(images, out_dir, cols=args.cols, thumb=args.thumb,
                        per_sheet=args.per_sheet)
    print(f"图像 {len(images)} 张 -> {len(made)} 页联络表")
    for p in made:
        print(f"  {p}")
    print(f"每页 {args.per_sheet or args.cols * 6} 张，缩略图宽 {args.thumb}px")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
