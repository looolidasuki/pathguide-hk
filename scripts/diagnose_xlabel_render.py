"""诊断 X-AnyLabeling 的渲染断言错误。

背景：在本项目生成的标注目录上启动 anylabeling 时报
    File ".../shape.py", line 161, in paint
        assert len(self.points) in [1, 2]
        AssertionError

该断言只针对 `shape_type == "rectangle"`：矩形必须有 1 或 2 个点。
本脚本用 anylabeling **自己的** Shape 与 QPainter 逐条复现，定位是哪一条标注出问题，
而不是靠推测。

用法（**必须用 .venv-label 的 python**）：
    .venv-label\\Scripts\\python.exe scripts\\diagnose_xlabel_render.py data/xtest/trashbin
"""
from __future__ import annotations

import json
import os
import sys
import traceback
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

REPO_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else (REPO_ROOT / "data" / "xtest" / "trashbin")
    if not target.is_absolute():
        target = REPO_ROOT / target
    if not target.is_dir():
        print(f"目录不存在：{target}")
        return 1

    try:
        from PyQt6 import QtCore, QtGui
        from anylabeling.views.labeling.shape import Shape
    except ImportError as exc:
        print(f"导入失败（请用 .venv-label 的 python 运行）：{exc}")
        return 1

    files = sorted(target.glob("*.json"))
    print(f"检查 {len(files)} 个 JSON -> {target}\n")

    # 用它在 GUI 里同样的方式绘制每个 shape
    image = QtGui.QImage(2000, 2000, QtGui.QImage.Format.Format_RGB32)
    painter = QtGui.QPainter(image)

    n_ok = n_fail = 0
    problems: list[tuple[str, int, str, int, list]] = []

    for jf in files:
        try:
            data = json.loads(jf.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            print(f"  [JSON错误] {jf.name}: {exc}")
            n_fail += 1
            continue

        for idx, s in enumerate(data.get("shapes", [])):
            st = s.get("shape_type")
            pts = s.get("points") or []
            sh = Shape(label=s.get("label"), text=s.get("text", ""),
                       shape_type=st, flags=s.get("flags") or {},
                       group_id=s.get("group_id"))
            # 复刻 label_widget 填入点的方式
            for p in pts:
                try:
                    sh.add_point(QtCore.QPointF(float(p[0]), float(p[1])))
                except Exception:  # noqa: BLE001
                    try:
                        sh.add_point(float(p[0]), float(p[1]))
                    except Exception as exc2:  # noqa: BLE001
                        problems.append((jf.name, idx, st, len(pts), [repr(exc2)]))
            if st == "rectangle":
                try:
                    sh.close()
                except Exception:  # noqa: BLE001
                    pass
            try:
                sh.paint(painter)
                n_ok += 1
            except AssertionError:
                n_fail += 1
                problems.append((jf.name, idx, st, len(sh.points),
                                 [f"paint 断言失败：len(points)={len(sh.points)}"]))
            except Exception as exc:  # noqa: BLE001
                n_fail += 1
                problems.append((jf.name, idx, st, len(sh.points),
                                 [f"{type(exc).__name__}: {exc}"]))

    painter.end()

    print(f"绘制成功 {n_ok} 个，失败 {n_fail} 个\n")
    if problems:
        print("问题清单：")
        for name, idx, st, npts, detail in problems[:30]:
            print(f"  {name} #shape{idx}  type={st}  实际点数={npts}")
            for d in detail:
                print(f"      {d}")
        print(f"\n共 {len(problems)} 条。")
    else:
        print("**全部通过** —— 说明崩溃源不在这批 JSON，"
              "而在 GUI 的交互路径（例如你手动画框、或打开了含其它标注的目录）。")

    # 额外报告：点数据本身是否有异常（NaN / 退化 / 越界）
    print("\n数据体检：")
    from PIL import Image

    odd = []
    for jf in files:
        data = json.loads(jf.read_text(encoding="utf-8"))
        jh, jw = data.get("imageHeight"), data.get("imageWidth")
        img_path = target / data.get("imagePath", "")
        real_wh = real_hw = None
        if img_path.exists():
            with Image.open(img_path) as im:
                real_wh = im.size          # PIL 的 size 是 (宽, 高)
                real_hw = (im.size[1], im.size[0])
        # 注意方向：JSON 的 imageHeight/Width 是 (高, 宽)，PIL 的 size 是 (宽, 高)。
        # 早先版本把 PIL 的 size 当成 (高, 宽) 比较，导致所有框都被误报为越界。
        if real_hw and (jh, jw) != real_hw:
            odd.append(f"{jf.name}: imageHeight/Width={jh},{jw} 与真实图 (高,宽)={real_hw} 不符")
        for idx, s in enumerate(data.get("shapes", [])):
            pts = s.get("points") or []
            for p in pts:
                if not all(isinstance(v, (int, float)) for v in p):
                    odd.append(f"{jf.name} #shape{idx}: 非数值点 {p}")
            if len(pts) == 2 and pts[0] == pts[1]:
                odd.append(f"{jf.name} #shape{idx}: 两个点重合 -> 退化矩形")
            if len(pts) == 2 and real_wh:
                w, h = real_wh
                xs = sorted(p[0] for p in pts)
                ys = sorted(p[1] for p in pts)
                if xs[0] < 0 or ys[0] < 0 or xs[1] > w or ys[1] > h:
                    odd.append(f"{jf.name} #shape{idx}: 点超出图像范围 "
                               f"(x {xs[0]:.1f}~{xs[1]:.1f} / w={w}; y {ys[0]:.1f}~{ys[1]:.1f} / h={h})")
    if odd:
        for o in odd[:20]:
            print(f"  [!] {o}")
        print(f"  共 {len(odd)} 项")
    else:
        print("  未发现 NaN / 退化 / 越界 / 尺寸不符")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
