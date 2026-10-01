"""量化「框越界」：来自哪批数据、越界幅度多大、是否值得处理。

check_labels.py 报 75 个 FATAL。但在决定处理方式之前要先看清：
- 若越界只有 1e-3 量级（边界取整），那是**导出精度**问题，不影响训练；
- 若有真实的大幅越界（比如框中心在 0.99、宽 0.5），那是标注错误，
  会给模型输入错误的监督信号。
把两者混为一谈就会做错决定（要么白改，要么放过真问题）。
"""
import collections
from pathlib import Path

ROOT = Path("data/dataset/labels")

oob = []
for src in sorted(ROOT.iterdir()):
    if not src.is_dir():
        continue
    for f in src.glob("*.txt"):
        for ln in f.read_text(encoding="utf-8", errors="replace").splitlines():
            p = ln.split()
            if len(p) < 5:
                continue
            try:
                x, y, w, h = (float(v) for v in p[1:5])
            except ValueError:
                continue
            x1, y1, x2, y2 = x - w / 2, y - h / 2, x + w / 2, y + h / 2
            over = max(0.0, -x1, -y1, x2 - 1.0, y2 - 1.0)
            if over > 0:
                oob.append((src.name, f.name, over, (x1, y1, x2, y2)))

print(f"越界的框共 {len(oob)} 个")
by_src = collections.Counter(s for s, _, _, _ in oob)
print("按来源：", dict(by_src))

if oob:
    overs = sorted(o for _, _, o, _ in oob)
    print(f"\n越界幅度：最小 {overs[0]:.2e}  中位 {overs[len(overs)//2]:.2e}  最大 {overs[-1]:.2e}")
    tiny = sum(1 for o in overs if o <= 1e-3)
    small = sum(1 for o in overs if 1e-3 < o <= 1e-2)
    big = sum(1 for o in overs if o > 1e-2)
    print(f"  <=1e-3（边界取整）      : {tiny}")
    print(f"  1e-3 ~ 1e-2（轻微越界）  : {small}")
    print(f"  > 1e-2（真实越界，需查）: {big}")
    print("\n最大的 8 个：")
    for s, f, o, box in sorted(oob, key=lambda t: -t[2])[:8]:
        print(f"  {o:.4f}  {s}/{f[:46]:<48} box=({box[0]:.3f},{box[1]:.3f})-({box[2]:.3f},{box[3]:.3f})")

# 总框数
tot = 0
for src in ROOT.iterdir():
    if src.is_dir():
        for f in src.glob("*.txt"):
            tot += len([l for l in f.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip()])
print(f"\n总框数 {tot}，越界占比 {len(oob)/max(1,tot)*100:.3f}%")
