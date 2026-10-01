"""从 configs/classes.json 生成各处的类别表。

## 为什么必须生成而不是手抄

类别索引是 YOLO 的标签契约。Dart 侧手抄一份列表，任何一次错位
（漏一行、顺序不同、改名）都会让 App 把 `bin` 的框标成 `bollard`——
**不会报任何错**，只是安静地标错。

项目已经因为「标签与索引错位」吃过一次亏（v1 删 street_obstacle 时 id 8–15
重排），所以这里宁可多一个生成步骤，也不留第二份事实源。

`configs/classes.txt` 就是一处**已经漂移过的**第二事实源：它当初是手抄的，
v3 把类别从 24 扩到 48 之后它还是旧内容，而 X-AnyLabeling 的配置正好读它——
标注工具会因此只认旧类别。现在它和 Dart 表一样由本脚本生成。

## 输出

- `app/lib/vision/labels.dart`：全部 `Label` 常量 + 按 id 索引的表 +
  按播报优先级排序的列表。
- `app/assets/labels.json`：同一份数据的 JSON，供需要热更新或调试时使用。
- `configs/classes.txt`：纯文本类别名清单（每行一个，按 id 升序），
  供 X-AnyLabeling 等外部工具读取。

用法：
    python scripts/gen_dart_labels.py
    python scripts/gen_dart_labels.py --check   # 只校验是否已同步（CI 用）
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
DART_PATH = REPO_ROOT / "app" / "lib" / "vision" / "labels.dart"
JSON_PATH = REPO_ROOT / "app" / "assets" / "labels.json"
TXT_PATH = REPO_ROOT / "configs" / "classes.txt"

# 播报紧急度：数字越小越先播。P0 = 立刻播（可能危险），P1 = 排队播。
PRIORITY_RANK = {"P0": 0, "P1": 1, "P2": 2}


def load_classes(path: Path = CLASSES_PATH) -> list[dict]:
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    classes = sorted(data["classes"], key=lambda c: c["id"])
    ids = [c["id"] for c in classes]
    if ids != list(range(len(classes))):
        raise ValueError(f"类别 id 必须是从 0 开始的连续整数，实际为 {ids}")
    return classes


def announcement_order(classes: list[dict]) -> list[int]:
    """播报顺序：先按 priority（P0 优先），再按 name_zh 笔画无关的稳定序。

    announced=False 的类（如 streetlight / sign_post）不参与播报，排在最后。
    """
    return [
        c["id"] for c in sorted(
            classes,
            key=lambda c: (0 if c.get("announced", True) else 1,
                           PRIORITY_RANK.get(c.get("priority", "P2"), 2),
                           c["id"]),
        )
    ]


def _dart_string(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def render_dart(classes: list[dict]) -> str:
    order = announcement_order(classes)
    lines = [
        "// 本文件由 scripts/gen_dart_labels.py 从 configs/classes.json 生成，请勿手工编辑。",
        "// 手工改动会在下次生成时被覆盖；要改类别请改 configs/classes.json。",
        "",
        "/// 一个检测类别。`id` 必须与 YOLO 标签索引一致。",
        "class Label {",
        "  const Label({",
        "    required this.id,",
        "    required this.nameEn,",
        "    required this.nameZh,",
        "    required this.group,",
        "    required this.priority,",
        "    required this.announced,",
        "  });",
        "",
        "  final int id;",
        "  final String nameEn;",
        "  final String nameZh;",
        "  final String group;",
        "",
        "  /// P0 表示可能危险，播报可插队；P1 排队播。",
        "  final String priority;",
        "",
        "  /// false 表示这类东西不该播报（如 streetlight：到处都有、又不可行动）。",
        "  final bool announced;",
        "",
        "  @override",
        "  String toString() => 'Label($id, $nameEn, $nameZh)';",
        "}",
        "",
        "/// 全部类别，按 id 升序。",
        "const List<Label> kLabels = <Label>[",
    ]
    for c in classes:
        lines += [
            "  Label(",
            f"    id: {c['id']},",
            f"    nameEn: {_dart_string(c['name_en'])},",
            f"    nameZh: {_dart_string(c['name_zh'])},",
            f"    group: {_dart_string(c.get('group', 'unknown'))},",
            f"    priority: {_dart_string(c.get('priority', 'P2'))},",
            f"    announced: {'true' if c.get('announced', True) else 'false'},",
            "  ),",
        ]
    lines += [
        "];",
        "",
        "/// 模型输出维度。推理结果长度与之不符即为模型与类别表不匹配。",
        f"const int kNumClasses = {len(classes)};",
        "",
        "/// 播报优先级顺序（先 announced，再 P0 → P1，再 id）。",
        "const List<int> kAnnouncementOrder = <int>[",
        "  " + ", ".join(str(i) for i in order) + ",",
        "];",
        "",
        "/// 按 id 取类别。id 越界时返回 null —— 不要静默回退到 0，那会掩盖模型/类别表不匹配。",
        "Label? labelOf(int id) => (id >= 0 && id < kLabels.length) ? kLabels[id] : null;",
        "",
    ]
    return "\n".join(lines)


def render_json(classes: list[dict]) -> str:
    payload = {
        "generated_from": "configs/classes.json",
        "note": "由 scripts/gen_dart_labels.py 生成，请勿手工编辑。",
        "num_classes": len(classes),
        "announcement_order": announcement_order(classes),
        "labels": [
            {
                "id": c["id"],
                "name_en": c["name_en"],
                "name_zh": c["name_zh"],
                "group": c.get("group", "unknown"),
                "priority": c.get("priority", "P2"),
                "announced": c.get("announced", True),
            }
            for c in classes
        ],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def render_txt(classes: list[dict]) -> str:
    """纯文本类别名清单：每行一个 name_en，按 id 升序。

    给外部工具用（X-AnyLabeling 的 `--labels-file`）。**行的顺序就是类别索引**，
    所以这里必须是 id 升序，不能排序或去重后重排——那会让标注工具里的
    类别编号与 YOLO 标签索引错位，而且两边都不报错。
    """
    return "".join(f"{c['name_en']}\n" for c in classes)


def _rel(path: Path) -> str:
    """尽量显示相对路径；路径在仓库外时退回绝对路径（测试会用 tmp_path）。"""
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def write_outputs(check: bool = False) -> int:
    classes = load_classes()
    dart = render_dart(classes)
    payload = render_json(classes)
    txt = render_txt(classes)
    stale = []
    for path, text in ((DART_PATH, dart), (JSON_PATH, payload), (TXT_PATH, txt)):
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != text:
            stale.append(path)
            if not check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
    if check:
        if stale:
            print("生成的类别表与 configs/classes.json 不同步：")
            for p in stale:
                print(f"  - {_rel(p)}")
            print("请运行 python scripts/gen_dart_labels.py")
            return 1
        print("类别表已同步。")
        return 0
    print(f"已生成 {len(classes)} 个类别")
    for p in (DART_PATH, JSON_PATH, TXT_PATH):
        print(f"  -> {_rel(p)}")
    if stale:
        for p in stale:
            print(f"     （已更新 {p.name}）")
    else:
        print("     （内容无变化）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="只检查是否与 configs/classes.json 同步，不写文件")
    args = ap.parse_args()
    return write_outputs(check=args.check)


if __name__ == "__main__":
    raise SystemExit(main())
