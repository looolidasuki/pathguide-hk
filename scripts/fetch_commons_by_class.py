"""从 Wikimedia Commons 采集训练数据（按 configs/commons_sources.json 的类别与分类）。

**香港分类优先**：先取 `Category:X in Hong Kong`，不足目标张数时再补全球分类。
理由：全球图存在街道风格偏移（欧美/日本 vs 香港），而本项目部署在香港。
来源与许可证逐张记入 attribution.jsonl，便于事后区分训练域与评测域。

产出结构（与 data/raw 的「一个来源一个文件夹」约定一致）：
    data/raw/external/<class_or_target>/<hk|global>_<seq>.jpg
    data/raw/external/attribution.jsonl

用法：
    python scripts/fetch_commons_by_class.py --per-class 60
    python scripts/fetch_commons_by_class.py --only bench tree --per-class 80
    python scripts/fetch_commons_by_class.py --in-taxonomy-only
"""
from __future__ import annotations

import argparse
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES_PATH = REPO_ROOT / "configs" / "commons_sources.json"
API = "https://commons.wikimedia.org/w/api.php"
UA = {"User-Agent": "PathGuideHKD-Research/0.1 (academic thesis; contact via repo)"}
THUMB_WIDTH = 1024        # 训练用足够，且比原图小得多
MIN_BYTES = 3000          # 小于此值多半是错误页


def api(params: dict) -> dict:
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.loads(r.read())
        except Exception as exc:  # noqa: BLE001
            if attempt == 3:
                print(f"      [WARN] API 失败：{type(exc).__name__}")
                return {}
            time.sleep(1.5 + attempt * 2)
    return {}


def _clean_html(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s or "")).strip()[:200]


def category_images(cat: str, limit: int) -> list[dict]:
    out: list[dict] = []
    cont: str | None = None
    while len(out) < limit:
        p = {"action": "query", "generator": "categorymembers", "gcmtitle": cat,
             "gcmtype": "file", "gcmlimit": "100", "prop": "imageinfo",
             "iiprop": "url|extmetadata|size", "iiurlwidth": str(THUMB_WIDTH),
             "format": "json"}
        if cont:
            p["gcmcontinue"] = cont
        d = api(p)
        for page in d.get("query", {}).get("pages", {}).values():
            ii = (page.get("imageinfo") or [{}])[0]
            if not ii.get("thumburl"):
                continue
            meta = ii.get("extmetadata", {})
            out.append({
                "title": page.get("title", ""),
                "category": cat,
                "thumburl": ii["thumburl"],
                "descurl": ii.get("descriptionurl", ""),
                "artist": _clean_html(meta.get("Artist", {}).get("value", "")),
                "license": meta.get("LicenseShortName", {}).get("value", ""),
                "license_url": meta.get("LicenseUrl", {}).get("value", ""),
            })
            if len(out) >= limit:
                break
        cont = d.get("continue", {}).get("gcmcontinue")
        if not cont:
            break
        time.sleep(0.35)
    return out


def download(url: str, dest: Path) -> bool:
    try:
        req = urllib.request.Request(url, headers=UA)
        with urllib.request.urlopen(req, timeout=90) as r:
            data = r.read()
        if len(data) < MIN_BYTES:
            return False
        dest.write_bytes(data)
        return True
    except Exception:  # noqa: BLE001
        return False


def is_hong_kong(cat: str) -> bool:
    return "hong kong" in cat.lower()


def fetch_one(name: str, categories: list[str], per_class: int, root: Path,
              attrib_f) -> dict:
    """先香港分类、后全球分类，凑够 per_class 张。"""
    out_dir = root / name
    out_dir.mkdir(parents=True, exist_ok=True)
    got = 0
    source_counts: dict[str, int] = {}

    for cat in categories:
        if got >= per_class:
            break
        tier = "hk" if is_hong_kong(cat) else "global"
        need = per_class - got
        items = category_images(cat, need)
        if not items:
            continue
        for it in items:
            got = len(list(out_dir.glob("*.jpg")))
            if got >= per_class:
                break
            # 命名带 tier 前缀，便于事后区分训练域/评测域
            idx = len(list(out_dir.glob(f"{tier}_*.jpg")))
            dest = out_dir / f"{tier}_{idx:04d}.jpg"
            while dest.exists():
                idx += 1
                dest = out_dir / f"{tier}_{idx:04d}.jpg"
            if download(it["thumburl"], dest):
                it.update({"class_or_target": name, "tier": tier,
                           "local_file": str(dest.relative_to(REPO_ROOT).as_posix())})
                attrib_f.write(json.dumps(it, ensure_ascii=False) + "\n")
            time.sleep(0.2)
        attrib_f.flush()

    # 按 tier 前缀扫描统计——**幂等**。
    # 早期版本用「本次下载数」，重跑时（文件已存在走 continue）会得到 0，
    # 导致分项与总数不符（实测出现「60 张 (香港 0 / 全球 0)」）。
    hk = len(list(out_dir.glob("hk_*.jpg")))
    gl = len(list(out_dir.glob("global_*.jpg")))
    return {"name": name, "saved": hk + gl, "hk_saved": hk, "global_saved": gl}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-class", type=int, default=60, help="每类目标张数")
    ap.add_argument("--only", nargs="*", default=None, help="只采集指定名称")
    ap.add_argument("--out", default="data/raw/external")
    ap.add_argument("--in-taxonomy-only", action="store_true",
                    help="只采类别表内的类，不采表外目标")
    ap.add_argument("--oot-only", action="store_true",
                    help="只采表外目标（用于验证哪些物件能靠网上数据冷启动）")
    args = ap.parse_args()

    with SOURCES_PATH.open(encoding="utf-8") as f:
        cfg = json.load(f)

    jobs: list[tuple[str, list[str]]] = []
    if not args.oot_only:
        for c in cfg["classes"]:
            jobs.append((c["name_en"], c["categories"]))
    if not args.in_taxonomy_only:
        for t in cfg["out_of_taxonomy_targets"]["targets"]:
            jobs.append((t["name"], t["categories"]))
    if args.only:
        want = set(args.only)
        jobs = [j for j in jobs if j[0] in want]
        if not jobs:
            print(f"--only 未匹配任何名称。可选：{[j[0] for j in jobs] or '见 configs/commons_sources.json'}")
            return 1

    root = REPO_ROOT / args.out
    root.mkdir(parents=True, exist_ok=True)
    attrib_path = root / "attribution.jsonl"

    print(f"目标：{len(jobs)} 个类/目标 × 每类 {args.per_class} 张")
    print("策略：**香港分类优先**，不足时补全球分类")
    print(f"输出：{root.relative_to(REPO_ROOT)}  （署名：{attrib_path.name}）\n")

    summary = []
    with attrib_path.open("a", encoding="utf-8") as af:
        for name, cats in jobs:
            res = fetch_one(name, cats, args.per_class, root, af)
            summary.append(res)
            flag = "OK " if res["saved"] >= args.per_class else ("部分" if res["saved"] else "空 ")
            print(f"  [{flag}] {name:18s} {res['saved']:>3} 张"
                  f"  (香港 {res['hk_saved']} / 全球 {res['global_saved']})")

    total = sum(r["saved"] for r in summary)
    empty = [r["name"] for r in summary if r["saved"] == 0]
    print(f"\n合计 {total} 张")
    if empty:
        print(f"\n零结果（{len(empty)}）：{', '.join(empty)}")
        print("  -> 这些类别 Commons 无存量，**必须实地采集**")

    (root / "fetch_summary.json").write_text(
        json.dumps({"per_class_target": args.per_class, "total": total,
                    "results": summary}, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n署名文件：{attrib_path.relative_to(REPO_ROOT)}")
    print("  **Commons 图像多为 CC BY / CC BY-SA，论文引用与发布必须列出署名。**")
    print(f"\n下一步：")
    print(f"  python scripts\\probe\\fetch_commons.py   # 若需更多香港专项")
    print(f"  用 gd_detect.py 跑类别发现，确认这些图里到底有什么")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
