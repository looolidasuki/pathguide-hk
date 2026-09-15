"""从 Wikimedia Commons 下载指定分类下的图片，并记录署名信息。

定位：**可行性探测（spike）专用，throwaway**。不是正式数据采集流水线。
正式采集见 docs/superpowers/plans/2026-09-15-pathguide-m0-m2-training-pipeline.md。

CC BY / CC BY-SA 类许可证要求署名，因此每张图都记录：
    文件名、分类、作者、许可证、描述页 URL、原图 URL
输出到 <out>/attribution.jsonl，供论文引用。

用法：
    python scripts/probe/fetch_commons.py --out data/probe/hk --per-cat 40
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UA = {"User-Agent": "PathGuideHKD-Research/0.1 (academic thesis feasibility probe)"}
API = "https://commons.wikimedia.org/w/api.php"
THUMB_WIDTH = 800

# 探测用物件 -> Commons 香港分类
HK_CATEGORIES: dict[str, list[str]] = {
    "trash_bin": ["Category:Rubbish bins in Hong Kong", "Category:Waste containers in Hong Kong"],
    "post_box": ["Category:Post boxes in Hong Kong"],
    "phone_booth": ["Category:Telephone booths in Hong Kong"],
    "bench": ["Category:Benches in Hong Kong"],
    "planter": ["Category:Planters in Hong Kong"],
    "traffic_light": ["Category:Traffic signals in Hong Kong"],
    "footbridge": ["Category:Footbridges in Hong Kong"],
    "escalator": ["Category:Escalators in Hong Kong"],
    "tactile_paving": ["Category:Tactile paving in Hong Kong"],
    "shop_sign": ["Category:Shop signs in Hong Kong"],
    "fire_hydrant": ["Category:Fire hydrants in Hong Kong"],
}


def api(params: dict) -> dict:
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=40) as r:
                return json.loads(r.read())
        except Exception as exc:  # noqa: BLE001
            if attempt == 3:
                print(f"    [WARN] API 失败：{type(exc).__name__}")
                return {}
            time.sleep(1.5 + attempt * 2)
    return {}


def category_images(cat: str, limit: int) -> list[dict]:
    """返回分类下的图片文件信息（含 imageinfo）。"""
    out: list[dict] = []
    cont: str | None = None
    while len(out) < limit:
        params = {
            "action": "query",
            "generator": "categorymembers",
            "gcmtitle": cat,
            "gcmtype": "file",
            "gcmlimit": "100",
            "prop": "imageinfo",
            "iiprop": "url|extmetadata|size",
            "iiurlwidth": str(THUMB_WIDTH),
            "format": "json",
        }
        if cont:
            params["gcmcontinue"] = cont
        d = api(params)
        pages = d.get("query", {}).get("pages", {})
        for page in pages.values():
            ii = (page.get("imageinfo") or [{}])[0]
            if not ii.get("thumburl"):
                continue
            meta = ii.get("extmetadata", {})
            out.append({
                "title": page.get("title", ""),
                "category": cat,
                "thumburl": ii["thumburl"],
                "descurl": ii.get("descriptionurl", ""),
                "artist": _clean(meta.get("Artist", {}).get("value", "")),
                "license": meta.get("LicenseShortName", {}).get("value", ""),
                "license_url": meta.get("LicenseUrl", {}).get("value", ""),
                "width": ii.get("width"),
                "height": ii.get("height"),
            })
            if len(out) >= limit:
                break
        cont = d.get("continue", {}).get("gcmcontinue")
        if not cont:
            break
        time.sleep(0.4)
    return out


def _clean(html: str) -> str:
    """粗粒度去除 extmetadata 里的 HTML 标签。"""
    import re

    text = re.sub(r"<[^>]+>", "", html or "")
    return re.sub(r"\s+", " ", text).strip()[:200]


def download(url: str, dest: Path) -> bool:
    try:
        req = urllib.request.Request(url, headers=UA)
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
        if len(data) < 2000:  # 过小多半是错误页
            return False
        dest.write_bytes(data)
        return True
    except Exception:  # noqa: BLE001
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/probe/hk")
    ap.add_argument("--per-cat", type=int, default=40)
    ap.add_argument("--only", default=None, help="只处理某个物件（键名）")
    args = ap.parse_args()

    out_root = REPO_ROOT / args.out
    out_root.mkdir(parents=True, exist_ok=True)
    attrib_path = out_root / "attribution.jsonl"

    targets = HK_CATEGORIES
    if args.only:
        targets = {k: v for k, v in HK_CATEGORIES.items() if k == args.only}
        if not targets:
            print(f"未知物件：{args.only}；可选：{list(HK_CATEGORIES)}")
            return 1

    summary: dict[str, int] = {}
    with attrib_path.open("a", encoding="utf-8") as alog:
        for obj, cats in targets.items():
            obj_dir = out_root / obj
            obj_dir.mkdir(parents=True, exist_ok=True)
            got = 0
            for cat in cats:
                if got >= args.per_cat:
                    break
                items = category_images(cat, args.per_cat - got)
                print(f"  {obj:16s} {cat}: API 返回 {len(items)} 张")
                for i, it in enumerate(items):
                    if got >= args.per_cat:
                        break
                    name = f"{obj}_{got:04d}.jpg"
                    dest = obj_dir / name
                    if dest.exists():
                        got += 1
                        continue
                    if download(it["thumburl"], dest):
                        it["local_file"] = str(dest.relative_to(REPO_ROOT).as_posix())
                        it["object"] = obj
                        alog.write(json.dumps(it, ensure_ascii=False) + "\n")
                        got += 1
                    time.sleep(0.25)
                alog.flush()
            summary[obj] = got
            print(f"  -> {obj}: 下载 {got} 张")

    print("\n=== 下载汇总 ===")
    for obj, n in summary.items():
        print(f"  {obj:16s} {n:4d}")
    print(f"\n署名信息：{attrib_path}")
    print(f"图像目录：{out_root}")
    print("\n提醒：探测用小集，仅用于评测，不用于训练。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
