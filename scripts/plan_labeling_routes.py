"""按类别规划「最省人工」的标注路径。

## 为什么需要这个

48 类 × 250 实例 ≈ 12,000 个框。手工从零画（每个框约 10 秒：拉框 5 秒 +
从 48 项下拉里选类 5 秒）≈ **33 小时起，且下拉选错不会报错**。
所以问题不是「怎么标得快一点」，而是**哪些类根本不需要手工从零画**。

## 判定依据（全部用本项目已实测的数据，不靠估计）

1. **我们的模型已经会哪些类** —— `runs/pg_poc3` 的 3 类里 `bin` 实测
   mAP50 0.948：这一类可以「模型预出框 + 人工确认」，不用从零画。
2. **COCO 自带哪些类** —— `pedestrian`/`bicycle` 可从 COCO 冷启动（已实测
   94% 的老师框被学生找回）。
3. **开放词表（YOLO-World）对每类的候选命中** —— 来自视频扫描报告。
   命中多的类可以出候选帧让模型预标；命中为 0 的类，模型帮不上忙。
4. **零召回 vs 低于门槛** —— `probe_missing_classes.py` 能把两者分开：
   前者只能人工/实拍，后者可降门槛。

## 四种路径

| 路径 | 人工做什么 | 适用条件 |
|---|---|---|
| `A 模型预标+确认` | 删掉错的、补漏的 | 我们已有/能拿到该类的可用模型 |
| `B 候选帧+人工画` | 画框，但下拉里只有这一类 | 无模型，但 YOLO-World 能给出候选帧 |
| `C 公开数据集` | 只做格式转换 | COCO / Open Images / Mapillary / Roboflow 里有该类 |
| `D 专项实拍` | 拍 + 画 | 模型完全没召回，且公开集没有（多为香港特有） |

用法：
    python scripts/plan_labeling_routes.py
    python scripts/plan_labeling_routes.py --markdown   # 输出可贴进文档的表格
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

SCAN_REPORT = REPO_ROOT / "data" / "frames" / "selected" / "report.md"
# 我们当前模型会认的类（本地索引 -> 真实 id），与 model_class_map.dart 对齐
OUR_MODEL_IDS = [6, 11, 7]
# COCO 能直接对应的类（实测：48 类里只有这 3 个对得上）
COCO_MAP = {6: "person", 11: "bicycle", 34: "dining table/chair（语义不等价，慎用）"}

# 实测零召回的类（probe_missing_classes.py，150 帧内最高分 < 0.05）
ZERO_RECALL = {
    "stairs", "footbridge_railing", "barrier_water", "step",
    "tree_root_on_the_road", "scaffold", "road_excavation",
    "caution_slippery", "barrier_fencing",
}
# 公开数据集里有对应类的（已核实类别名）
PUBLIC_DATASET = {
    "stairs": "Open Images `Stairs`；Roboflow stairs_detection 等",
    "step": "Mapillary Vistas `Curb`（= 台階/路緣）",
    "bin": "Open Images `Waste container`；Mapillary `Trash Can`",
    "bicycle": "COCO `bicycle`（已用）",
    "fence": "Mapillary `Fence`",
    "barrier_fencing": "Mapillary `Barrier`（近似）",
    "scaffold": "中文施工安全数据集（10600 张，近似）",
    "billboard": "Open Images `Billboard`；Mapillary `Billboard`",
    "streetlight": "Open Images `Street light`；Mapillary `Street Light`",
    "sign_pictogram": "Open Images `Traffic sign`；Mapillary `Traffic Sign (Front)`",
    "table": "Open Images `Table`/`Chair`（语义不等价，慎用）",
    "pedestrian": "COCO `person`（已用）",
    "caution_slippery": "Roboflow 有施工警示牌类数据集（需核对）",
}

# 人工每个框的现实成本（秒），用于估算总量
SEC_PREFILL_CONFIRM = 3      # 确认/删除/微调一个预标框
SEC_DRAW_PER_CLASS_BATCH = 7  # 候选帧批里画框（下拉只有一类，不用找类别）
SEC_DRAW_FROM_SCRATCH = 10    # 从零画：拉框 + 48 项下拉里找类


def load_classes() -> list[dict]:
    cfg = json.loads((REPO_ROOT / "configs" / "classes.json").read_text(encoding="utf-8"))
    return sorted(cfg["classes"], key=lambda c: c["id"])


def parse_scan_hits() -> dict[str, int]:
    """从扫描报告的「逐类候选情况」表里读每类的候选帧数。"""
    if not SCAN_REPORT.exists():
        return {}
    hits: dict[str, int] = {}
    for m in re.finditer(r"^\|\s*([a-z0-9_]+)\s*\|\s*(\d+)\s*\|", 
                         SCAN_REPORT.read_text(encoding="utf-8"), re.M):
        hits[m.group(1)] = int(m.group(2))
    return hits


def route_for(c: dict, hits: dict[str, int]) -> tuple[str, str]:
    """返回 (路径代号, 理由)。判定顺序即优先级。"""
    name = c["name_en"]
    if c["id"] in OUR_MODEL_IDS:
        return "A", "我们的模型已经会这一类（bin 实测 mAP50 0.948）"
    if c["id"] in COCO_MAP:
        return "A", f"COCO 自带 `{COCO_MAP[c['id']]}`，可冷启动（实测老师框回收 94%）"
    if name in PUBLIC_DATASET:
        return "C", f"公开数据集有对应类：{PUBLIC_DATASET[name]}"
    if name in ZERO_RECALL:
        return "D", "开放词表**零召回**（实测最高分 < 0.05），模型给不出候选"
    n = hits.get(name, 0)
    if n >= 100:
        return "A", f"YOLO-World 候选 {n} 帧，可先预标再人工确认（噪声较大，需核对）"
    if n >= 10:
        return "B", f"YOLO-World 候选仅 {n} 帧，量少但能圈定范围"
    return "B", f"YOLO-World 候选 {n} 帧（几乎扫不到），需人工在候选帧里画"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true", help="只输出 markdown 表格")
    ap.add_argument("--target", type=int, default=250, help="每类目标实例数")
    args = ap.parse_args()

    classes = load_classes()
    hits = parse_scan_hits()
    rows = []
    for c in classes:
        route, why = route_for(c, hits)
        rows.append((c, route, why))

    order = {"A": 0, "C": 1, "B": 2, "D": 3}
    rows.sort(key=lambda r: (order[r[1]], r[0]["id"]))

    counts = {k: 0 for k in order}
    for _, r, _ in rows:
        counts[r] += 1
    per_route_seconds = {
        "A": args.target * SEC_PREFILL_CONFIRM,
        "B": args.target * SEC_DRAW_PER_CLASS_BATCH,
        "C": args.target * SEC_PREFILL_CONFIRM * 0.5,   # 只需格式转换+抽检
        "D": args.target * SEC_DRAW_FROM_SCRATCH,
    }
    total_from_scratch = len(classes) * args.target * SEC_DRAW_FROM_SCRATCH
    total_routed = sum(per_route_seconds[r] * counts[r] for r in order)

    if not args.markdown:
        print(f"类别 {len(classes)} 个，每类目标 {args.target} 实例\n")
        print(f"{'路径':<4}{'类数':<6}{'每类人工':<12}{'该类合计':<12}说明")
        print("-" * 78)
        names = {"A": "模型预标+确认", "B": "候选帧+人工画",
                 "C": "公开数据集", "D": "专项实拍"}
        for r in order:
            each = per_route_seconds[r] / 60
            print(f"{r:<4}{counts[r]:<6}{each:>6.1f} 分钟   "
                  f"{per_route_seconds[r] * counts[r] / 3600:>6.1f} 小时   {names[r]}")
        print("-" * 78)
        print(f"全部从零手工画：{total_from_scratch / 3600:.1f} 小时")
        print(f"按路径分流后  ：{total_routed / 3600:.1f} 小时"
              f"（省 {100 * (1 - total_routed / total_from_scratch):.0f}%）")
        print(f"\n假设：预标确认 {SEC_PREFILL_CONFIRM}s/框、单类批画框 "
              f"{SEC_DRAW_PER_CLASS_BATCH}s/框、从零画 {SEC_DRAW_FROM_SCRATCH}s/框")
        print("\n逐类明细：")
        print(f"{'id':<4}{'类名':<30}{'路径':<5}理由")
        print("-" * 100)
        for c, r, why in rows:
            print(f"{c['id']:<4}{c['name_en']:<30}{r:<5}{why}")
    else:
        print("| id | 类别 | 路径 | 理由 |")
        print("|---|---|---|---|")
        for c, r, why in rows:
            print(f"| {c['id']} | `{c['name_en']}` | **{r}** | {why} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
