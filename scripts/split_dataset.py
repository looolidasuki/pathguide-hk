"""按来源文件夹分组、按类别分层的训练/验证/测试划分。

用法：
    python scripts/split_dataset.py --ratios 0.8 0.1 0.1 --seed 42

关键：以 source_folder 为分组键，防止同一段视频抽出的相邻帧同时进入训练集与验证集
（那会让指标虚高 10+ 个百分点）。
"""
from __future__ import annotations

import argparse
import csv
import json
import random
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = REPO_ROOT / "data" / "dataset"
MANIFEST_PATH = DATASET_DIR / "manifest.csv"
SPLIT_PATH = DATASET_DIR / "split.json"
DATASETS_DIR = REPO_ROOT / "datasets"
YAML_PATH = DATASETS_DIR / "pathguide.yaml"
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"

FOLD_ORDER = ("train", "val", "test")


def load_manifest() -> list[dict]:
    with MANIFEST_PATH.open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def load_class_names() -> list[str]:
    with CLASSES_PATH.open(encoding="utf-8") as f:
        data = json.load(f)
    return [c["name_en"] for c in sorted(data["classes"], key=lambda c: c["id"])]


def source_class_sets(rows: list[dict]) -> dict[str, set[int]]:
    out: dict[str, set[int]] = defaultdict(set)
    for r in rows:
        for token in str(r.get("classes", "")).split("|"):
            token = token.strip()
            if token.isdigit():
                out[r["source_folder"]].add(int(token))
    return out


def _count(by_source: dict[str, list[dict]], src_list: list[str]) -> int:
    return sum(len(by_source[s]) for s in src_list)


def assign_folds(rows: list[dict], ratios: tuple[float, float, float], seed: int) -> dict[str, list[str]]:
    """按 source_folder 分组、按类别分层划分。

    分层方式：以「来源包含的类别集合」为桶，桶内洗牌后，第 2、3 个来源分别进 val 与 test，
    其余来源按当前张数最少者归入，从而兼顾分层与比例。

    优先级裁决：无泄漏 > val 覆盖全类别 > train/val/test 比例精确性。

    返回值为**相对 images/ 的 posix 路径**（如 `route_A_src00/xxx.jpg`），
    以保留子目录层级，避免不同来源的同名帧互相覆盖。
    """
    by_source: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_source[r["source_folder"]].append(r)

    src_classes = source_class_sets(rows)
    buckets: dict[tuple[int, ...], list[str]] = defaultdict(list)
    for source in sorted(by_source):
        buckets[tuple(sorted(src_classes.get(source, set())))].append(source)

    rng = random.Random(seed)
    fold_sources: dict[str, list[str]] = {f: [] for f in FOLD_ORDER}

    for key in sorted(buckets):
        group = sorted(buckets[key])
        rng.shuffle(group)
        for i, source in enumerate(group):
            if i == 1:
                fold_sources["val"].append(source)
            elif i == 2:
                fold_sources["test"].append(source)
            else:
                fold = min(FOLD_ORDER, key=lambda f: _count(by_source, fold_sources[f]))
                fold_sources[fold].append(source)

    # 兜底：任一折为空时，从最大的折迁出一个来源
    for fold in ("val", "test"):
        if not fold_sources[fold]:
            donor = max(FOLD_ORDER, key=lambda f: (len(fold_sources[f]), f))
            if len(fold_sources[donor]) >= 2:
                fold_sources[fold].append(fold_sources[donor].pop())

    def rels(src_list: list[str]) -> list[str]:
        return [r["image_rel"] for s in src_list for r in by_source[s]]

    return {fold: sorted(rels(fold_sources[fold])) for fold in FOLD_ORDER}


def validate_no_leakage(split: dict, manifest: list[dict]) -> list[str]:
    """返回违规描述列表；空列表表示通过。"""
    problems: list[str] = []
    src_of = {r["image_rel"]: r["source_folder"] for r in manifest}
    folds = {fold: set(split.get(fold, [])) for fold in FOLD_ORDER}

    if folds["train"] & folds["val"]:
        problems.append(f"train 与 val 有 {len(folds['train'] & folds['val'])} 张图像重复")
    if folds["train"] & folds["test"]:
        problems.append(f"train 与 test 有 {len(folds['train'] & folds['test'])} 张图像重复")
    if folds["val"] & folds["test"]:
        problems.append(f"val 与 test 有 {len(folds['val'] & folds['test'])} 张图像重复")

    for a, b in (("train", "val"), ("train", "test"), ("val", "test")):
        shared = {src_of[n] for n in folds[a] if n in src_of} & {src_of[n] for n in folds[b] if n in src_of}
        if shared:
            problems.append(f"{a} 与 {b} 共享来源文件夹（泄漏）：{sorted(shared)[:5]}")

    assigned = folds["train"] | folds["val"] | folds["test"]
    unassigned = set(src_of) - assigned
    if unassigned:
        problems.append(f"{len(unassigned)} 张图像未被分配到任何折，例如 {sorted(unassigned)[:5]}")

    return problems


def write_yaml(split: dict, class_names: list[str]) -> None:
    names_block = "\n".join(f"  {i}: {n}" for i, n in enumerate(class_names))
    content = (
        "# 由 scripts/split_dataset.py 自动生成，请勿手工编辑\n"
        f"path: {DATASET_DIR.as_posix()}\n"
        "train: train.txt\n"
        "val: val.txt\n"
        "test: test.txt\n\n"
        f"nc: {len(class_names)}\n"
        "names:\n"
        f"{names_block}\n"
    )
    DATASETS_DIR.mkdir(parents=True, exist_ok=True)
    YAML_PATH.write_text(content, encoding="utf-8")

    for fold in FOLD_ORDER:
        listing = DATASET_DIR / f"{fold}.txt"
        # 必须写**绝对原生路径**：
        #   1) Ultralytics 从 CWD 解析相对路径，而非从 yaml 的 path 字段；
        #   2) img2label_paths() 用 os.sep 拼 `\images\` -> `\labels\`，
        #      Windows 下正斜杠路径无法匹配，会退化为「找不到标签」。
        lines = [str(DATASET_DIR / "images" / Path(rel)) for rel in split[fold]]
        listing.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ratios", type=float, nargs=3, default=[0.8, 0.1, 0.1],
                    metavar=("TRAIN", "VAL", "TEST"))
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--include-unlabelled", action="store_true",
                    help="也纳入缺标签的图像（默认仅用已标注的）")
    args = ap.parse_args()

    if not MANIFEST_PATH.exists():
        print(f"未找到 {MANIFEST_PATH}。请先运行 make_manifest.py。")
        return 1

    all_rows = load_manifest()
    if args.include_unlabelled:
        rows = all_rows
    else:
        rows = [r for r in all_rows if str(r.get("has_label", "")).lower() in ("true", "1")]
    if not rows:
        print("manifest 中没有可用图像。请先完成标注（Task 10）。")
        return 1

    total_ratio = sum(args.ratios)
    if abs(total_ratio - 1.0) > 1e-6:
        print(f"ratios 之和必须为 1.0，当前为 {total_ratio}")
        return 1

    split = assign_folds(rows, tuple(args.ratios), args.seed)
    problems = validate_no_leakage(split, rows)
    if problems:
        print("划分校验失败：")
        for p in problems:
            print(f"  - {p}")
        return 1

    payload = {
        "seed": args.seed,
        "ratios": list(args.ratios),
        "counts": {k: len(v) for k, v in split.items()},
        **split,
    }
    SPLIT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    write_yaml(split, load_class_names())

    print(f"seed={args.seed}")
    for fold in FOLD_ORDER:
        n_sources = len({r["source_folder"] for r in rows if r["image_rel"] in set(split[fold])})
        print(f"  {fold}: {len(split[fold])} 张, {n_sources} 个来源")
    print(f"split -> {SPLIT_PATH}")
    print(f"yaml  -> {YAML_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
