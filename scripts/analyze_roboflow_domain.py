"""用**可计算的指标**判断 Roboflow 数据集的域与标签质量。

为什么不用肉眼看：① 判断要可复现、可写进文档；② 抽查 48 张看不出
「7261 张整体是什么分布」。下面每个指标都对应一个具体判断：

| 指标 | 说明什么 |
|---|---|
| 图幅与长宽比 | CCTV/航拍常是 16:9 或极端比例；手机街景多是 3:4 / 9:16 |
| 灰度图占比 | CCTV、热成像数据集大量是灰度——本项目部署在彩色行人视角 |
| 每图框数 | 4 框/图以上通常是人潮/CCTV/体育场景，不是街边偶发行人 |
| 框相对尺寸 | 框占图高 5% 以下 = 远处或俯视人群；街边行人多为 20%~80% |
| 框长宽比 | 只有头的标注约 1:1，全身约 1:2~1:4 |
| 框中心纵向分布 | 大量框挤在画面上半部 → 机位偏高（俯视） |
| 类别共现 | 与哪些类一起出现，能反推上游来源数据集 |
"""
from __future__ import annotations

import collections
import json
import statistics
import sys
from pathlib import Path

import cv2

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
from import_roboflow import read_yaml_names  # noqa: E402

root = REPO_ROOT / "data/raw/roboflow"
names = read_yaml_names(root / "data.yaml")
ov = json.loads((root / "_class_override.json").read_text(encoding="utf-8"))
KEEP = {i: ov[n] for i, n in enumerate(names) if n in ov}

# 均匀抽样（覆盖三个 split），控制耗时
imgs = []
for split in ("train", "valid", "test"):
    d = root / split / "images"
    lst = sorted(p for p in d.glob("*") if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
    imgs += lst[:: max(1, len(lst) // 500)][:500]
print(f"分析 {len(imgs)} 张（从 {sum(len(list((root/s/'images').glob('*'))) for s in ('train','valid','test'))} 张里均匀抽样）")

# ---------- 图幅、色彩、每图框数 ----------
wh = collections.Counter()
aspect = []
gray = 0
n_box_per_img = []
label_exist = 0

# ---------- 框几何（只统计**映射上的**框）----------
box_w_frac, box_h_frac, box_ar, box_cy = [], [], [], []
cls_count = collections.Counter()
cooccur = collections.Counter()

for p in imgs:
    img = cv2.imread(str(p), cv2.IMREAD_COLOR)
    if img is None:
        continue
    h, w = img.shape[:2]
    wh[(w, h)] += 1
    aspect.append(w / h)
    # 灰度判定：三个通道几乎相同即为灰度图
    small = cv2.resize(img, (64, 64))
    b, g, r = small[:, :, 0].astype(int), small[:, :, 1].astype(int), small[:, :, 2].astype(int)
    diff = (abs(b - g) + abs(b - r) + abs(g - r)).mean()
    if diff < 3.0:
        gray += 1

    lbl = root / p.parent.parent.name / "labels" / f"{p.stem}.txt"
    n = 0
    present = set()
    if lbl.exists():
        label_exist += 1
        for ln in lbl.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = ln.split()
            if len(parts) < 5:
                continue
            try:
                cid = int(float(parts[0]))
                x, y, bw, bh = (float(v) for v in parts[1:5])
            except ValueError:
                continue
            n += 1
            if cid in KEEP:
                box_w_frac.append(bw)
                box_h_frac.append(bh)
                box_ar.append(bw / bh if bh > 0 else 0)
                box_cy.append(y)
                cls_count[names[cid] if cid < len(names) else str(cid)] += 1
                present.add(KEEP[cid])
    n_box_per_img.append(n)
    if len(present) > 1:
        cooccur[tuple(sorted(present))] += 1


def pct(vals, q):
    if not vals:
        return float("nan")
    s = sorted(vals)
    return s[min(len(s) - 1, int(q * len(s)))]


print(f"\n===== 图幅（最常见的 6 种）=====")
for (w, h), c in wh.most_common(6):
    print(f"  {w}x{h:<6} {c:>4} 张   宽高比 {w/h:.2f}")

print(f"\n===== 色彩 =====")
print(f"  灰度图 {gray}/{len(imgs)} = {gray/max(1,len(imgs))*100:.1f}%")
print("  （灰度占比高说明含 CCTV/热成像/老照片来源，与本项目彩色手机视角不同）")

print(f"\n===== 每图框数（全部类别）=====")
print(f"  均值 {statistics.mean(n_box_per_img):.2f}  中位数 {statistics.median(n_box_per_img):.0f}  "
      f"最大 {max(n_box_per_img)}")
print(f"  有标签文件 {label_exist}，其中空标签（负样本）"
      f" {sum(1 for v in n_box_per_img if v == 0)}")

print(f"\n===== 映射上的框：几何 =====")
print(f"  共 {len(box_h_frac)} 框")
print(f"  框高占图比  中位数 {statistics.median(box_h_frac):.3f}  "
      f"10%分位 {pct(box_h_frac,0.10):.3f}  90%分位 {pct(box_h_frac,0.90):.3f}")
print(f"  框宽占图比  中位数 {statistics.median(box_w_frac):.3f}")
print(f"  框长宽比(宽/高) 中位数 {statistics.median(box_ar):.3f}  "
      f"10% {pct(box_ar,0.10):.3f}  90% {pct(box_ar,0.90):.3f}")
print(f"  框中心纵向位置 中位数 {statistics.median(box_cy):.3f}  "
      f"（0.5 = 画面正中；明显小于 0.5 说明框偏上 = 机位偏高）")
tiny = sum(1 for v in box_h_frac if v < 0.10) / max(1, len(box_h_frac)) * 100
huge = sum(1 for v in box_h_frac if v > 0.60) / max(1, len(box_h_frac)) * 100
print(f"  极小框（高<10%图高）{tiny:.1f}%   极大框（高>60%图高）{huge:.1f}%")

print(f"\n===== 映射上的框：按类别名 =====")
for k, v in cls_count.most_common():
    print(f"  {k:<14} {v:>6}")

print(f"\n===== 同时出现多个映射类别的图 =====")
for k, v in cooccur.most_common(5):
    print(f"  {k}: {v} 张")
