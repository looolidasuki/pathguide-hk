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

from single_source import SingleSourceSplitError, single_source_folds

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


def load_class_names(path: Path | None = None) -> list[str]:
    if path is None:
        path = CLASSES_PATH
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    return [c["name_en"] for c in sorted(data["classes"], key=lambda c: c["id"])]


def resolve_class_names(dataset_dir: Path) -> list[str]:
    """优先用**数据集自带的** classes.json，其次回退到项目类别表。

    ★ 这不是可选优化，而是正确性问题。单类数据集
    （data/dataset_single_bin）的标签索引被重写为 0，而项目类别表里 0 是
    `footbridge_entrance`。若此处用项目表，写出的 yaml 会声明 `nc: 24`
    且 `0: footbridge_entrance`，于是标签里的 "0"（垃圾桶）被当成天桥入口训练——
    **训练不报错，只是类别全错**，而且会一路带到导出的模型里。
    """
    local = dataset_dir / "classes.json"
    if local.exists():
        return load_class_names(local)
    return load_class_names(CLASSES_PATH)


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


def write_yaml(split: dict, class_names: list[str], dataset_dir: Path | None = None,
               datasets_dir: Path | None = None, yaml_path: Path | None = None) -> None:
    dataset_dir = dataset_dir or DATASET_DIR
    datasets_dir = datasets_dir or DATASETS_DIR
    yaml_path = yaml_path or (datasets_dir / "pathguide.yaml")
    names_block = "\n".join(f"  {i}: {n}" for i, n in enumerate(class_names))
    content = (
        "# 由 scripts/split_dataset.py 自动生成，请勿手工编辑\n"
        f"path: {dataset_dir.as_posix()}\n"
        "train: train.txt\n"
        "val: val.txt\n"
        "test: test.txt\n\n"
        f"nc: {len(class_names)}\n"
        "names:\n"
        f"{names_block}\n"
    )
    datasets_dir.mkdir(parents=True, exist_ok=True)
    yaml_path.write_text(content, encoding="utf-8")

    for fold in FOLD_ORDER:
        listing = dataset_dir / f"{fold}.txt"
        # 必须写**绝对原生路径**：
        #   1) Ultralytics 从 CWD 解析相对路径，而非从 yaml 的 path 字段；
        #   2) img2label_paths() 用 os.sep 拼 `\images\` -> `\labels\`，
        #      Windows 下正斜杠路径无法匹配，会退化为「找不到标签」。
        lines = [str(dataset_dir / "images" / Path(rel)) for rel in split[fold]]
        listing.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def check_split_files(dataset_dir: Path | None = None) -> list[str]:
    """划分产物是否可用。返回问题描述列表，空列表表示通过。

    空折必须被显式拦下：空 val 让训练跑不起来，空 test 让评测给出假指标。
    而且要在**这里**说清是哪个折为空，别让训练脚本只报「val.txt 缺失」——
    那句错误信息完全指不到真实原因（单来源数据无法分组划分）。
    """
    dataset_dir = dataset_dir or DATASET_DIR
    problems: list[str] = []
    for fold in FOLD_ORDER:
        listing = dataset_dir / f"{fold}.txt"
        if not listing.exists():
            problems.append(f"{fold} 划分清单不存在：{listing}")
        elif not listing.read_text(encoding="utf-8").strip():
            problems.append(f"{fold} 划分清单为空：{listing}")
    return problems


def run_split(dataset_dir: Path | None = None, ratios: tuple[float, float, float] = (0.8, 0.1, 0.1),
              seed: int = 42, include_unlabelled: bool = False,
              datasets_dir: Path | None = None, manifest_path: Path | None = None) -> dict | int:
    """执行划分。成功返回 split 字典，失败返回退出码 1。"""
    dataset_dir = dataset_dir or DATASET_DIR
    datasets_dir = datasets_dir or DATASETS_DIR
    manifest_path = manifest_path or (dataset_dir / "manifest.csv")

    if not manifest_path.exists():
        print(f"未找到 {manifest_path}。请先运行 make_manifest.py。")
        return 1

    with manifest_path.open(encoding="utf-8-sig", newline="") as f:
        all_rows = list(csv.DictReader(f))
    if include_unlabelled:
        rows = all_rows
    else:
        rows = [r for r in all_rows if str(r.get("has_label", "")).lower() in ("true", "1")]
    if not rows:
        print("manifest 中没有可用图像。请先完成标注（Task 10）。")
        return 1

    srcs = sorted({r["source_folder"] for r in rows})
    single = len(srcs) == 1

    if single:
        # 分组防泄漏划分在单来源下无从下手（会把全部图像丢进一个折），
        # 退到等间隔取样，并明确标注「同源，指标偏乐观」。
        try:
            split = single_source_folds([r["image_rel"] for r in rows], ratios)
        except SingleSourceSplitError as e:
            print(f"无法划分：{e}")
            return 1
        print(f"**单来源数据集（{srcs[0]}）：已退到等间隔取样划分。")
        print(  "  同源划分无法防泄漏——相邻帧几乎相同，指标会偏乐观，"
                "只能用于跑通链路，不能作为最终性能证据。")
    else:
        split = assign_folds(rows, ratios, seed)

    problems = validate_no_leakage(split, rows)
    if single:
        # 单来源必然「共享来源文件夹」，那不是缺陷，是我们已知且已声明的限制
        problems = [p for p in problems if "共享来源文件夹" not in p]
    if problems:
        print("划分校验失败：")
        for p in problems:
            print(f"  - {p}")
        return 1

    payload = {
        "seed": seed,
        "ratios": list(ratios),
        "counts": {k: len(v) for k, v in split.items()},
        "single_source": single,
        "single_source_note": (
            "单来源等间隔取样：同源划分无法防泄漏，指标偏乐观，仅用于跑通链路"
            if single else ""
        ),
        **split,
    }
    (dataset_dir / "split.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    # 用**数据集自己**的类别表，而不是项目表。单类数据集的标签索引被重写为 0，
    # 用项目表会把 0 写成 footbridge_entrance，导致类别整体错位且训练不报错。
    write_yaml(split, resolve_class_names(dataset_dir), dataset_dir, datasets_dir)

    for fold in FOLD_ORDER:
        n_sources = len({r["source_folder"] for r in rows if r["image_rel"] in set(split[fold])})
        print(f"  {fold}: {len(split[fold])} 张, {n_sources} 个来源")
    return payload


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ratios", type=float, nargs=3, default=[0.8, 0.1, 0.1],
                    metavar=("TRAIN", "VAL", "TEST"))
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--include-unlabelled", action="store_true",
                    help="也纳入缺标签的图像（默认仅用已标注的）")
    ap.add_argument("--dataset-dir", type=Path, default=DATASET_DIR,
                    help="数据集根目录（含 images/ labels/ manifest.csv）。"
                         "单类库请指向 data/dataset_single_bin，避免覆盖主库 yaml。")
    args = ap.parse_args()

    total_ratio = sum(args.ratios)
    if abs(total_ratio - 1.0) > 1e-6:
        print(f"ratios 之和必须为 1.0，当前为 {total_ratio}")
        return 1

    dataset_dir = args.dataset_dir.resolve()
    print(f"seed={args.seed}  dataset={dataset_dir}")
    result = run_split(dataset_dir=dataset_dir,
                       ratios=tuple(args.ratios), seed=args.seed,
                       include_unlabelled=args.include_unlabelled)
    if result == 1:
        return 1
    print(f"split -> {dataset_dir / 'split.json'}")
    print(f"yaml  -> {YAML_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
