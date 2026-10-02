"""测 poc5 在香港 val 图上的**新类误报率** —— 这是 val mAP 看不见的盲区。

## 为什么必须单独测

ultralytics 的 ap_per_class 只对 **GT 里出现过的类** 算 AP；预测到其它类的框
**直接被丢掉，不计入任何指标**。而 poc5 的 val 里，那 15 个新类
（obstacle / escalator / door / fence / …）**一个实例都没有**。

于是：**poc5 在真实香港街景上把这些类误检多少次，val 指标里完全看不到。**
「总体 P 0.658」可能掩盖着满屏误报。

这正是本项目最怕的失败模式：指标看着没问题，实际不能用。

做法：对 val 的 103 张香港实拍图跑预测，统计**每个类在 conf≥0.70（播报门槛）
处的检出次数**。这些图里没有这些物体，所以检出的都是误报。
"""
from __future__ import annotations

import collections
import io
from contextlib import redirect_stdout
from pathlib import Path

from ultralytics import YOLO

SPEAK = 0.70
DISPLAY = 0.30
D = Path("data/dataset_poc5")
val_imgs = sorted((D / "images" / "val").glob("*"))
print(f"val 图 {len(val_imgs)} 张（香港实拍，无第三方数据）")

# val 里真实有标注的类（本地索引）
gt_classes = collections.Counter()
for f in (D / "labels" / "val").glob("*.txt"):
    for ln in f.read_text(encoding="utf-8").splitlines():
        if ln.strip():
            gt_classes[int(ln.split()[0])] += 1
print(f"val 的 GT 类别：{dict(gt_classes)}")

m = YOLO("runs/pg_poc5/weights/best.pt")
with redirect_stdout(io.StringIO()):
    res = m.predict([str(p) for p in val_imgs], imgsz=416, conf=DISPLAY,
                    verbose=False, device=0)

fire_speak = collections.Counter()
fire_display = collections.Counter()
imgs_with_speak_fp = 0
for r in res:
    names = r.names
    hit = False
    for b in r.boxes:
        ci = int(b.cls)
        cf = float(b.conf)
        if ci not in gt_classes:          # ← val 里没有这个类的 GT，检出即误报
            fire_display[names[ci]] += 1
            if cf >= SPEAK:
                fire_speak[names[ci]] += 1
                hit = True
    if hit:
        imgs_with_speak_fp += 1

print(f"\n=== 在 val 上**检出了 val 里不存在的类**的次数（即误报）===")
print(f"{'类':<26}{'conf>=0.30':>12}{'conf>=0.70(播报)':>18}")
allc = set(fire_display) | set(fire_speak)
for c in sorted(allc, key=lambda k: -fire_speak.get(k, 0)):
    print(f"{c:<26}{fire_display.get(c,0):>12}{fire_speak.get(c,0):>18}")
if not allc:
    print("  （无）")

print(f"\n在播报门槛处至少误报一次的图：{imgs_with_speak_fp} / {len(val_imgs)} "
      f"({imgs_with_speak_fp/len(val_imgs)*100:.1f}%)")
print("\n对照：GT 里有实例的类（pedestrian/bicycle/bin）的检出次数")
for r in res[:0]:
    pass
fire_gt = collections.Counter()
for r in res:
    for b in r.boxes:
        ci = int(b.cls)
        if ci in gt_classes and float(b.conf) >= SPEAK:
            fire_gt[names[ci]] += 1
print(f"  conf>=0.70 的检出：{dict(fire_gt)}")
