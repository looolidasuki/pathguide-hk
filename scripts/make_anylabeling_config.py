"""生成 X-AnyLabeling 的配置文件（`.anylabelingrc`）。

## 为什么需要这个脚本

X-AnyLabeling 默认把配置写在 `~/.anylabelingrc`。在受限环境（或你想把配置随项目走）时，
需要用 `--config` 指定路径。但它的 `get_config()` 逻辑是：

    yaml.safe_load(参数)  ->  若结果不是 dict，就当作**文件路径**打开

所以 `--config .anylabelingrc` 指向一个**不存在的文件**时，会直接抛
`FileNotFoundError: '.anylabelingrc'`——**不做回退、不报友好提示**。

必须先有这个文件。本脚本从 anylabeling 自带的默认模板生成，并写入：
  - `labels`：本项目的全部类别（顺序与 configs/classes.json 一致，由
    scripts/gen_dart_labels.py 生成到 configs/classes.txt）
  - `label_colors`：按组的配色，便于人工复核时一眼区分

用法：
    python scripts/make_anylabeling_config.py
    python scripts/make_anylabeling_config.py --out .anylabelingrc --labels-file configs/classes.txt
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"

# 按组配色（RGB 0-255）。同组同色系，便于复核时快速判断框属于哪一类。
GROUP_COLORS: dict[str, tuple[int, int, int]] = {
    "footbridge": (255, 80, 80),     # 天桥专项 —— 红
    "obstacle": (255, 165, 0),       # 路面障碍 —— 橙
    "guide": (60, 160, 255),         # 导引设施 —— 蓝
    "indoor": (170, 90, 255),        # 室内 —— 紫
    "classifier": (0, 200, 140),     # 分类器专用 —— 青绿
    "train_only": (128, 128, 128),   # 训练专用 —— 灰
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=".anylabelingrc")
    ap.add_argument("--labels-file", default=None,
                    help="只写 labels 列表（每行一个类名），配色用默认")
    args = ap.parse_args()

    out = REPO_ROOT / args.out

    # 1) 从 anylabeling 自带模板起步——不要手写全部 125 行，容易漏字段
    try:
        import anylabeling

        tmpl = Path(anylabeling.__file__).parent / "configs" / "anylabeling_config.yaml"
        base = tmpl.read_text(encoding="utf-8")
        source = f"anylabeling 默认模板 ({tmpl.name})"
    except Exception as exc:  # noqa: BLE001
        base = ""
        source = f"空（读取模板失败：{type(exc).__name__}）"

    # 2) 取类别
    if args.labels_file:
        names = [l.strip() for l in
                 (REPO_ROOT / args.labels_file).read_text(encoding="utf-8").splitlines()
                 if l.strip()]
        colors = None
    else:
        with CLASSES_PATH.open(encoding="utf-8") as f:
            classes = sorted(json.load(f)["classes"], key=lambda c: c["id"])
        names = [c["name_en"] for c in classes]
        colors = {c["name_en"]: GROUP_COLORS.get(c["group"], (200, 200, 200))
                  for c in classes}

    def yaml_list(items: list[str], indent: int = 0) -> str:
        pad = " " * indent
        return "\n".join(f"{pad}- {x}" for x in items)

    # 3) 构造覆盖段。labels 与 label_colors 是我们要覆盖的关键字段。
    lines = [
        "# 由 scripts/make_anylabeling_config.py 生成，勿手工编辑",
        f"# 模板来源：{source}",
        f"# 类别数：{len(names)}（顺序与 configs/classes.json 一致，不可重排）",
        "",
        "language: zh_CN",
        "theme: dark",
        "auto_save: true",
        "store_data: false",
        "shape_color: auto",
        "",
        "labels:",
        yaml_list(names),
        "",
    ]
    if colors:
        lines.append("label_colors:")
        for n in names:
            r, g, b = colors[n]
            lines.append(f"  {n}: [{r}, {g}, {b}]")
        lines.append("")

    # 4) 保留模板里的其余字段（画布、dock、快捷键等），避免缺字段
    if base:
        keep: list[str] = []
        skip = False
        skip_keys = {"labels", "label_colors", "language", "theme", "auto_save", "store_data", "shape_color"}
        for line in base.splitlines():
            if line and not line.startswith((" ", "#")) and ":" in line:
                key = line.split(":", 1)[0].strip()
                skip = key in skip_keys
            if not skip:
                keep.append(line)
        lines += ["", "# ---- 以下沿用 anylabeling 默认值 ----", ""] + keep

    out.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"已生成 {out.relative_to(REPO_ROOT)}")
    print(f"  模板：{source}")
    print(f"  类别：{len(names)} 个")
    if colors:
        groups: dict[tuple[int, int, int], list[str]] = {}
        for n in names:
            groups.setdefault(colors[n], []).append(n)
        print(f"  配色：{len(groups)} 组")
        for rgb, ns in groups.items():
            print(f"    RGB{rgb}  {', '.join(ns[:3])}{' …' if len(ns) > 3 else ''}")
    # ★ 这里打印的启动命令必须**能直接复制粘贴执行**。
    #
    # 以前写的是 `.venv-label\Scripts\anylabeling.exe ...`，在 PowerShell 里
    # 因为开头是 `.` 会被当成模块名去解析，报
    #   The module '.venv-label' could not be loaded
    # ——用户按提示操作却起不来，还以为是环境坏了。前面补 `.\` 就不会被误解析。
    # 路径一律写绝对路径，避免「在哪个目录执行」也变成一个坑。
    exe = REPO_ROOT / ".venv-label" / "Scripts" / "anylabeling.exe"
    print(f"\n启动（PowerShell，可直接复制）：\n"
          f"  .\\{exe.relative_to(REPO_ROOT)} --config \"{out}\" "
          f"\"{(REPO_ROOT / 'data' / 'frames' / 'label_me' / 'myVideo')}\"")
    if not exe.exists():
        print(f"  [WARN] 找不到 {exe}，请先建好标注环境")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

