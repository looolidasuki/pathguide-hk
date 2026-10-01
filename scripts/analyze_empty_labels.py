"""查清那 2096 张「空标签」图里到底有什么。

它们本来是「源里有框，但框全是未映射类」，写出来就变空标签 = 负样本。
对车辆、椅子这类我们不要的物件，变成背景是**正确**的。
但如果图里有人被标成了 `Cyclist` / `player` / `head` / `face`，
那这 2096 张就在教模型「这里没有人」—— 那会**主动损害** pedestrian 类。

所以这一步不是走形式，是决定这批数据能不能用的关键一票。
"""
import collections
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path("scripts").resolve()))
from import_roboflow import read_yaml_names  # noqa: E402

root = Path("data/raw/roboflow")
names = read_yaml_names(root / "data.yaml")
ov = json.loads((root / "_class_override.json").read_text(encoding="utf-8"))

# 与「人」相关、但被我们**故意不映射**的类别
PERSON_LIKE = {"cyclist", "Cyclist", "player", "head", "face", "helmet", "persons",
               "person", "people", "Pedestrian", "Pedestrians", "Persona", "Pessoa"}

empty_imgs = 0
empty_with_personlike = 0
mapped_imgs = 0
unmapped_only_hist = collections.Counter()
personlike_detail = collections.Counter()
examples = []

for split in ("train", "valid", "test"):
    for p in (root / split / "images").glob("*"):
        lbl = root / split / "labels" / f"{p.stem}.txt"
        if not lbl.exists():
            continue
        rows = []
        for ln in lbl.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = ln.split()
            if len(parts) < 5:
                continue
            try:
                cid = int(float(parts[0]))
            except ValueError:
                continue
            rows.append(cid)
        if not rows:
            continue
        has_mapped = any(cid < len(names) and names[cid] in ov for cid in rows)
        if has_mapped:
            mapped_imgs += 1
            continue
        # 全部未映射 -> 写出来是空标签
        empty_imgs += 1
        clss = [names[cid] if cid < len(names) else str(cid) for cid in rows]
        for c in set(clss):
            unmapped_only_hist[c] += 1
        pl = [c for c in set(clss) if c in PERSON_LIKE]
        if pl:
            empty_with_personlike += 1
            for c in pl:
                personlike_detail[c] += 1
            if len(examples) < 8:
                examples.append((p.name, clss))

print(f"有标签文件的图：{mapped_imgs + empty_imgs}")
print(f"  至少有一个映射上的框（成为正样本）：{mapped_imgs}")
print(f"  全部框都未映射（写出来是空标签=负样本）：{empty_imgs}")
print(f"\n其中**含人形/人体部位类**的：{empty_with_personlike}  "
      f"({empty_with_personlike/max(1,empty_imgs)*100:.1f}% of 空标签图)")
if personlike_detail:
    print("  涉及哪些类：")
    for k, v in personlike_detail.most_common():
        print(f"    {k:<14} {v}")

print("\n空标签图里出现的未映射类（前 15）：")
for k, v in unmapped_only_hist.most_common(15):
    print(f"  {k:<16} {v}")

print("\n样例：")
for name, clss in examples:
    print(f"  {name[:52]:<54} {sorted(set(clss))}")
