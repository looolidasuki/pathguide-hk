"""把多个单类数据集合并成一个多类数据集（本地索引重排 + 按帧合并标签）。

## 为什么不能简单拼接

`bicycle` 与 `pedestrian` 的自动标注来自**同一批帧**。如果把两份数据集直接
拼起来，同一张图会出现两次：一次只有人的框、一次只有自行车的框。
训练时模型看到的是「这张图里没有人」（因为那次没标），
于是**学会抑制**本该出现的类。这类标签缺失是隐性错误的典型：
指标看着还行，实际是互相打架。

所以本脚本按**源图身份**聚合：同一张图的所有来源标签先合并，再写一份。

## 本地索引 vs 真实 id

数据集内部用**本地索引 0..nc-1**（YOLO 只接受这个范围，写真实 id 会导致
「标签格式非法」而**全部样本被丢弃**）。真实 id 记在 `classes.json` 的
`original_id` 里，由 App 侧做映射。这与单类模型是同一套机制。

用法：
    python scripts/build_multiclass_dataset.py --out data/dataset_poc3 \
        --add data/dataset_person_poc:pedestrian \
        --add data/dataset_bicycle_poc:bicycle \
        --add data/dataset_single_bin:bin
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def safe_stem(name: str, limit: int = 100) -> str:
    """文件名清成安全字符，并保证**唯一性**。

    空格/逗号在下游工具链里会被切断（本项目已两次踩到）。但这里更关键的是第二条：

    抽帧文件名是 `<视频名>_<帧号>.jpg`，**唯一的帧号在最末尾**。
    早先的写法是 `safe_stem(name)[:92]` —— 视频名本身就超过 92 字符，
    于是几百张图被截成同一个名字、互相覆盖，最终只写出去 47 个文件，
    而脚本还高高兴兴打印「合并 545 张」。**静默覆盖比报错危险得多**，
    所以这里既保留末尾（帧号），又用哈希兜底，调用方还会再做一次碰撞检查。
    """
    safe = re.sub(r"_{2,}", "_", re.sub(r"[^A-Za-z0-9_.-]", "_", name))
    if len(safe) <= limit:
        return safe
    h = hashlib.md5(safe.encode("utf-8")).hexdigest()[:8]
    return f"{safe[: limit - 30]}_{h}_{safe[-12:]}"


def load_classes_json() -> dict[str, int]:
    cfg = json.loads((REPO_ROOT / "configs" / "classes.json").read_text(encoding="utf-8"))
    return {c["name_en"]: c["id"] for c in cfg["classes"]}


def find_label(src_dir: Path, image: Path) -> Path | None:
    """按同样的 stem 在源的 labels/ 下递归找标签。"""
    for p in (src_dir / "labels").rglob(f"{image.stem}.txt"):
        return p
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--add", action="append", required=True,
                    metavar="DIR:OUR_CLASS",
                    help="单类数据集目录:它在本项目类别表里的类名（可给多次）")
    ap.add_argument("--val-ratio", type=float, default=0.2)
    args = ap.parse_args()

    name2id = load_classes_json()
    specs = []
    for i, item in enumerate(args.add):
        d, _, cls = item.rpartition(":")
        if not d or cls not in name2id:
            print(f"--add 格式不对或类名不在类别表里：{item}")
            return 1
        src = Path(d)
        if not src.is_absolute():
            src = REPO_ROOT / src
        if not src.exists():
            print(f"源目录不存在：{src}")
            return 1
        specs.append((src, cls, i))          # 本地索引按 --add 的顺序分配
    print("本地索引分配：")
    for src, cls, idx in specs:
        print(f"  {idx} = {cls}（真实 id {name2id[cls]}）   <- {src.name}")

    # ---- 按**帧名**聚合标签（不是按源文件路径）----
    #
    # 这里踩过一次：person 与 bicycle 的自动标注来自**同一批原始帧**，
    # 但各自把帧复制进了自己的数据集、**路径不同**。
    # 按源文件路径做键时，同一张图会被当成两张、各自只带一类的标签——
    # 恰好就是本节开头要避免的那个有害情况（教模型抑制另一类）。
    # 两个派生数据集都沿用原始帧名，因此**帧名才是帧的身份**。
    merged: dict[str, list[str]] = {}
    origin: dict[str, Path] = {}
    counts = {cls: 0 for _, cls, _ in specs}
    for src, cls, idx in specs:
        images = sorted(p for p in src.rglob("*")
                        if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
        used = 0
        for img in images:
            lbl = find_label(src, img)
            if lbl is None:
                continue
            lines = []
            for line in lbl.read_text(encoding="utf-8").splitlines():
                parts = line.split()
                if len(parts) < 5:
                    continue
                # 源里的类 id 一律当成本地索引 0（单类数据集都是这么写的），
                # 重排成本数据集的目标本地索引。
                lines.append(f"{idx} " + " ".join(parts[1:5]))
                counts[cls] += 1
            if lines:
                merged.setdefault(img.name, []).extend(lines)
                origin.setdefault(img.name, img)
                used += 1
        print(f"  {cls}: {used} 张图有标签（累计唯一帧 {len(merged)}）")

    if not merged:
        print("没有任何有效标签")
        return 1

    # ---- 写出（标准目录布局；不要用 txt 列表，路径解析规则与 path 无关）----
    out = Path(args.out)
    if not out.is_absolute():
        out = REPO_ROOT / out
    if out.exists():
        shutil.rmtree(out)
    for sub in ("train", "val"):
        (out / "images" / sub).mkdir(parents=True)
        (out / "labels" / sub).mkdir(parents=True)

    # ---- 切分：按「涉及哪些类」分组，组内再按时间顺序 ----
    #
    # 这里踩过一次：先前用**全局**时间顺序切分，结果 val 里只剩行人类——
    # 44 张垃圾桶照片的文件名以 `b` 开头、排在 `myVideo_...` 之前，全落进 train；
    # 13 张自行车帧在视频前段，也全落进 train。于是 val 的 275 个实例**全是行人**，
    # bin/bicycle 的指标根本算不出来，而汇总数字照样好看。
    #
    # 分组切分同时满足两件事：每类都出现在 val；组内仍按时间顺序（无近邻泄漏）。
    groups: dict[frozenset[int], list[str]] = {}
    for name, lines in merged.items():
        keys = frozenset(int(l.split()[0]) for l in lines)
        groups.setdefault(keys, []).append(name)

    train_items: list[str] = []
    val_items: list[str] = []
    for keys, names_in_group in sorted(groups.items(), key=lambda kv: sorted(kv[0])):
        ordered = sorted(names_in_group)
        n_val_g = max(1, int(len(ordered) * args.val_ratio)) if len(ordered) > 1 else 0
        cut_g = len(ordered) - n_val_g
        train_items.extend(ordered[:cut_g])
        val_items.extend(ordered[cut_g:])
        label = "+".join(cls for _, cls, idx in specs if idx in keys)
        print(f"  分组 [{label}]: {len(ordered)} 张 -> train {cut_g} / val {n_val_g}")

    rows = []
    written: dict[str, Path] = {}
    for split, chunk in (("train", train_items), ("val", val_items)):
        for name in chunk:
            img = origin[name]
            lines = merged[name]
            stem = safe_stem(Path(name).stem)
            out_name = f"{stem}{img.suffix}"
            # ★ 碰撞必须报错，不能覆盖。
            # 覆盖的表现是「脚本说合并了 N 张，磁盘上却只有几十张」——
            # 而这几十张照样能训出一个看似正常的模型，问题要到很后面才暴露。
            if out_name in written:
                raise SystemExit(
                    f"文件名碰撞：{out_name}\n"
                    f"  来自 {img}\n  与 {written[out_name]} 撞名。\n"
                    f"  请修改 safe_stem 的命名规则，不要靠截断来消歧。")
            written[out_name] = img
            shutil.copy2(img, out / "images" / split / out_name)
            (out / "labels" / split / f"{stem}.txt").write_text(
                "\n".join(lines) + "\n", encoding="utf-8")
            rows.append({"split": split, "name": out_name,
                         "source_image": str(img), "boxes": len(lines)})

    classes = [{"id": idx, "name_en": cls, "name_zh": "", "group": "poc",
                "priority": "P0", "announced": True, "original_id": name2id[cls]}
               for _, cls, idx in specs]
    (out / "classes.json").write_text(json.dumps({
        "version": 1,
        "note": "由 scripts/build_multiclass_dataset.py 合并生成。本地索引 0..nc-1；"
                "original_id 是它在 configs/classes.json 里的真实 id，"
                "由 App 侧的 modelClassIds 做映射。",
        "classes": classes,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    yaml_lines = [f"# 由 scripts/build_multiclass_dataset.py 生成",
                  f"path: {out.as_posix()}",
                  "train: images/train", "val: images/val", "names:"]
    yaml_lines += [f"  {c['id']}: {c['name_en']}" for c in classes]
    (out / "dataset.yaml").write_text("\n".join(yaml_lines) + "\n", encoding="utf-8")

    with (out / "manifest.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["split", "name", "source_image", "boxes"])
        w.writeheader()
        w.writerows(rows)

    n_train = sum(1 for r in rows if r["split"] == "train")
    print(f"\n合并 {len(merged)} 张（train {n_train} / val {len(rows) - n_train}）")
    print("逐类框数：" + "  ".join(f"{k}={v}" for k, v in counts.items()))
    print(f"输出：{out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())



