"""判断截图里到底有没有「可检测的内容」。

我看不了图，但 `det=0` 有两种完全不同的原因，处理方式相反：
- 截图是黑屏/纯色 -> 相机没取到画面（环境/权限/预览问题），与模型无关；
- 截图是正常场景 -> 模型在该场景下真的一帧都没检出，那是**回归**。

所以不能只看 det=0 就下结论，要先量画面本身。
"""
from pathlib import Path

import cv2
import numpy as np

for p in sorted(Path("artifacts/device").glob("shot_*.png")):
    img = cv2.imread(str(p), cv2.IMREAD_COLOR)
    if img is None:
        print(f"{p.name}: 读取失败")
        continue
    h, w = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mean = float(gray.mean())
    std = float(gray.std())
    # 近黑像素占比
    dark = float((gray < 12).mean())
    # 边缘密度：正常场景有大量边缘；纯色/模糊画面接近 0
    edges = cv2.Canny(gray, 60, 180)
    edge_frac = float((edges > 0).mean())
    # 唯一颜色数（量化后）：纯色画面极少
    small = (img // 16).reshape(-1, 3)
    uniq = len(np.unique(small, axis=0))
    print(f"{p.name}  {w}x{h}")
    print(f"  亮度均值 {mean:6.1f}  标准差 {std:6.1f}  近黑占比 {dark*100:5.1f}%")
    print(f"  边缘密度 {edge_frac*100:5.2f}%  量化后颜色数 {uniq}")
    verdict = ("画面基本为空（黑屏/纯色）-> 相机没取到内容"
               if std < 8 or edge_frac < 0.002
               else "画面有实际内容 -> det=0 是模型的检出问题")
    print(f"  判断：{verdict}")
    print()
