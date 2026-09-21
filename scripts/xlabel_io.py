"""X-AnyLabeling JSON <-> 数据集 的桥梁：读取、校验、写回 YOLO。

## 为什么需要这个脚本

**X-AnyLabeling 的 JSON 在人工复核之后就是最终标注真相。**
`data/dataset/labels/` 里躺着的是三阶段自动标注的产物，人工在 GUI 里改框
只写回同名 `.json`，不会回头改 `.txt`。所以「人工复核完成」这件事本身
不等于数据集变好——必须有一个显式的回写步骤。

它同时承担质检：人工框最常见的五类问题是
退化框、越界、极小框、同类近重复、标签名打错。
这些问题**不会让训练报错**，只会让 mAP 悄悄变低，所以必须显式挑出来。

## 读

`points` 是**绝对像素坐标** `[[x1,y1],[x2,y2]]`（读自其 label_file.py）。
只接受 `shape_type == "rectangle"`；多边形/空点集会被跳过而不是抛异常——
GUI 在画框途中会临时造一个空 points 的 Shape（`shape.py:161` 的断言就在那），
那种 shape 若被写进文件，读的时候必须容错。

## 写

YOLO 一行是 `class_id cx cy w h`，全部归一化到 [0,1]。
手工画的框可能带 1e-9 级越界，写之前夹紧，否则 Ultralytics 会静默丢框。

用法：
    # 只看质检报告（不改任何文件）
    python scripts/xlabel_io.py check --json-dir data/xtest/trashbin

    # 复核后写回数据集标签
    python scripts/xlabel_io.py emit --json-dir data/xtest/trashbin \\
        --labels-out data/dataset/labels/trashbin --report data/xtest/check.csv
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

from pipeline.label_taxonomy import iou_xyxy, normalize_text  # noqa: E402

CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
# train_only 是训练期占位类，属于「暂时无法判定的垂直设施」。
# 它允许出现在标注里供后续分拣，但不该进数据集——否则模型会学一个语义空洞的类。
NOT_A_TRAIN_CLASS = {"ambiguous_vertical"}


# ---------------------------------------------------------------- 类别表

def load_class_names(path: Path = CLASSES_PATH) -> list[str]:
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    return [c["name_en"] for c in sorted(data["classes"], key=lambda c: c["id"])]


def _key(text: str) -> str:
    """把 `cart_trolley` / `Cart-Trolley` / `cart trolley` 归一到同一把钥匙。

    normalize_text 会把下划线当标点吃掉，所以再补一次分隔符折叠。
    """
    return " ".join(normalize_text(text).replace("_", " ").split())


def resolve_label(text: str, names: list[str] | None = None) -> int | None:
    """标签名 -> class_id。名字不认识就返回 None，**绝不猜**。"""
    names = names or load_class_names()
    key = _key(text)
    if not key:
        return None
    for i, n in enumerate(names):
        if n in NOT_A_TRAIN_CLASS:
            continue
        if _key(n) == key:
            return i
    return None


# ------------------------------------------------------------- 读 JSON

def rect_xyxy(shape: dict) -> tuple[float, float, float, float] | None:
    """取矩形的像素 xyxy。非矩形 / 点数不是 2 / 非法数值 -> None。"""
    if shape.get("shape_type", "rectangle") != "rectangle":
        return None
    pts = shape.get("points") or []
    if len(pts) != 2:
        return None
    try:
        (x1, y1), (x2, y2) = pts
        x1, y1, x2, y2 = float(x1), float(y1), float(x2), float(y2)
    except (TypeError, ValueError):
        return None
    if (x1, y1, x2, y2) != (x1, y1, x2, y2):        # NaN
        return None
    # 手工拖拽可能反向，统一成 x1<=x2, y1<=y2
    if x1 > x2:
        x1, x2 = x2, x1
    if y1 > y2:
        y1, y2 = y2, y1
    return x1, y1, x2, y2


def read_shapes(json_path: Path) -> tuple[list[dict], tuple[int, int] | None]:
    """读一个 JSON。返回 (shape 列表, (w, h))。坏 shape 被跳过。"""
    with json_path.open(encoding="utf-8") as f:
        data = json.load(f)
    w, h = data.get("imageWidth"), data.get("imageHeight")
    size = (int(w), int(h)) if w and h else None
    shapes = []
    for s in data.get("shapes") or []:
        if rect_xyxy(s) is None:
            continue
        shapes.append(s)
    return shapes, size


# --------------------------------------------------------------- 质检

def box_failures(xyxy, size, min_side: float = 2.0, extreme_ratio: float = 8.0,
                 warnings_out: list | None = None) -> list[str]:
    """返回致命问题列表；可疑但可保留的问题写进 warnings_out。"""
    x1, y1, x2, y2 = xyxy
    w_img, h_img = size
    fails: list[str] = []
    if x1 < 0 or y1 < 0 or x2 > w_img or y2 > h_img:
        fails.append("oob")
    bw, bh = x2 - x1, y2 - y1
    if bw <= 0 or bh <= 0:
        fails.append("degenerate")
        return fails
    if bw < min_side or bh < min_side:
        fails.append("tiny")
    if extreme_ratio and max(bw, bh) / min(bw, bh) >= extreme_ratio:
        if warnings_out is not None:
            warnings_out.append("extreme_ratio")
    return fails


def find_duplicates(boxes, iou_thr: float = 0.8):
    """同标签、高 IoU 的框对。boxes = [(conf, label, xyxy), ...]。

    每对返回 (i, j, iou)，i 是**应保留**的那个（conf 更高的顺序在前）。
    """
    by_label: dict[str, list[int]] = defaultdict(list)
    for i, (_, label, _) in enumerate(boxes):
        by_label[label].append(i)
    out = []
    for idxs in by_label.values():
        for a in range(len(idxs)):
            for b in range(a + 1, len(idxs)):
                i, j = idxs[a], idxs[b]
                iou = iou_xyxy(boxes[i][2], boxes[j][2])
                if iou >= iou_thr:
                    out.append((i, j, iou))
    return out


# ------------------------------------------------------------- 写 YOLO

def to_yolo_line(cid: int, xyxy, size, precision: int = 6) -> str:
    x1, y1, x2, y2 = xyxy
    w_img, h_img = size
    vals = [
        ((x1 + x2) / 2.0) / w_img,
        ((y1 + y2) / 2.0) / h_img,
        (x2 - x1) / w_img,
        (y2 - y1) / h_img,
    ]
    vals = [min(1.0, max(0.0, v)) for v in vals]      # 夹紧 1e-9 级越界
    return f"{cid} " + " ".join(f"{v:.{precision}f}" for v in vals)


def class_counts(boxes) -> dict[str, int]:
    return dict(Counter(label for _, label, _ in boxes))


# ------------------------------------------------------- 目录级汇总

@dataclass
class BoxRecord:
    file: str
    index: int
    label: str
    conf: float
    xyxy: tuple[float, float, float, float]
    size: tuple[int, int]
    failures: list[str]
    warnings: list[str]


@dataclass
class ScanReport:
    boxes: list[BoxRecord]
    unknown_labels: dict[str, int]
    n_duplicates: int
    files: list[str]
    n_shapes_raw: int          # 文件里实际出现的 shape 数（含被跳过的坏 shape）

    @property
    def kept(self) -> list[BoxRecord]:
        return [b for b in self.boxes if not b.failures]


def scan_dir(json_dir: Path, strict: bool = True, min_side: float = 2.0,
             extreme_ratio: float = 8.0, iou_thr: float = 0.8) -> ScanReport:
    """扫一个 X-AnyLabeling JSON 目录，产出可写回数据集的框集合。

    strict=True：未知标签名直接剔除（默认，保护数据集）。
    strict=False：未知标签名保留为 warning，供人工分拣。
    """
    names = load_class_names()
    boxes: list[BoxRecord] = []
    unknown: dict[str, int] = Counter()
    n_raw = 0
    files: list[str] = []

    for jp in sorted(json_dir.glob("*.json")):
        raw = json.loads(jp.read_text(encoding="utf-8"))
        n_raw += len(raw.get("shapes") or [])
        w, h = raw.get("imageWidth"), raw.get("imageHeight")
        shapes, _ = read_shapes(jp)
        files.append(jp.name)
        for i, s in enumerate(shapes):
            label = s.get("label", "")
            xyxy = rect_xyxy(s)
            assert xyxy is not None
            warns: list[str] = []
            fails: list[str] = []
            if w and h:
                fails = box_failures(xyxy, (int(w), int(h)), min_side,
                                     extreme_ratio, warns)
            if resolve_label(label, names) is None:
                if strict:
                    fails.append("unknown_label")
                    unknown[label] += 1
                else:
                    unknown[label] += 1
                    warns.append("unknown_label")
            boxes.append(BoxRecord(jp.name, i, label, 1.0, xyxy,
                                   (int(w or 0), int(h or 0)), fails, warns))

    # 近似重复：只在同一文件内比较；保留先出现的那个（人工标注顺序即意图）
    dup_idx: set[int] = set()
    for fname in files:
        local = [b for b in boxes if b.file == fname and not b.failures
                 and resolve_label(b.label, names) is not None]
        pairs = find_duplicates([(b.conf, b.label, b.xyxy) for b in local], iou_thr)
        for _, j, _ in pairs:
            local[j].failures.append("near_duplicate")
            dup_idx.add(id(local[j]))

    return ScanReport(boxes, dict(unknown), len(dup_idx), files, n_raw)


def emit_labels(report: ScanReport, out_dir: Path) -> int:
    """写回 YOLO 标签，返回写出的文件数。坏框被剔除，空图写空文件。

    空文件是**必要**的：YOLO 把「有图无标签」当负样本；若整个文件缺失，
    Ultralytics 会直接报标签找不到。
    """
    names = load_class_names()
    out_dir.mkdir(parents=True, exist_ok=True)
    per_file: dict[str, list[str]] = defaultdict(list)
    for b in report.boxes:
        if b.failures:
            continue
        cid = resolve_label(b.label, names)
        if cid is None:
            continue
        per_file[b.file].append(to_yolo_line(cid, b.xyxy, b.size))
    for f in report.files:
        (out_dir / f"{Path(f).stem}.txt").write_text(
            "\n".join(per_file.get(f, [])), encoding="utf-8")
    return len(report.files)


def report_markdown(report: ScanReport) -> str:
    names = load_class_names()
    kept = report.kept
    lines = [
        "# 人工复核质检报告",
        "",
        f"- 文件：{len(report.files)}",
        f"- 文件内 shape 总数：{report.n_shapes_raw}",
        f"- 可读矩形：{len(report.boxes)}（被跳过的非矩形/坏点集："
        f"{report.n_shapes_raw - len(report.boxes)}）",
        f"- **可写入数据集：{len(kept)}**",
        f"- 有致命问题的框：{len(report.boxes) - len(kept)}",
        f"- 近似重复被剔除：{report.n_duplicates}",
        "",
    ]
    if report.unknown_labels:
        lines += ["## 未知标签名（不在 classes.json 中）", ""]
        for k, v in sorted(report.unknown_labels.items(), key=lambda kv: -kv[1]):
            lines.append(f"- `{k}` × {v}")
        lines.append("")

    lines += ["## 每类实例数（仅合法框）", "", "| class | id | instances |",
              "| --- | --- | --- |"]
    cnt = Counter(b.label for b in kept)
    for i, n in enumerate(names):
        if cnt.get(n):
            lines.append(f"| {n} | {i} | {cnt[n]} |")
    lines += ["", f"合计 {sum(cnt.values())} 个实例", ""]

    bad = [b for b in report.boxes if b.failures]
    if bad:
        lines += ["## 问题框明细", "", "| file | # | label | 问题 | xyxy |",
                  "| --- | --- | --- | --- | --- |"]
        for b in bad:
            xy = ",".join(f"{v:.0f}" for v in b.xyxy)
            lines.append(f"| {b.file} | {b.index} | {b.label} | "
                         f"{','.join(b.failures)} | {xy} |")
        lines.append("")
    return "\n".join(lines)


def write_csv(report: ScanReport, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["file", "index", "label", "class_id", "x1", "y1", "x2", "y2",
                    "verdict", "warnings"])
        names = load_class_names()
        for b in report.boxes:
            cid = resolve_label(b.label, names)
            w.writerow([b.file, b.index, b.label,
                        "" if cid is None else cid,
                        *[f"{v:.1f}" for v in b.xyxy],
                        "drop" if b.failures else "keep",
                        ",".join(b.failures + b.warnings)])


# ------------------------------------------------------------------ CLI

def _resolve(p: str | None) -> Path | None:
    if p is None:
        return None
    path = Path(p)
    return path if path.is_absolute() else (REPO_ROOT / path)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name, help_text in (("check", "只出质检报告，不改任何文件"),
                            ("emit", "质检后写回 YOLO 标签")):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--json-dir", required=True, help="X-AnyLabeling JSON 目录")
        p.add_argument("--report", default=None, help="Markdown 报告输出路径")
        p.add_argument("--csv", default=None, help="逐框 CSV 输出路径")
        p.add_argument("--labels-out", default=None, help="emit：YOLO 标签输出目录")
        p.add_argument("--min-side", type=float, default=2.0,
                       help="短边下限（像素），低于此判死")
        p.add_argument("--extreme-ratio", type=float, default=8.0,
                       help="长宽比阈值，超过只警告（栏杆这类细长物是合法的）")
        p.add_argument("--iou-thr", type=float, default=0.8,
                       help="同标签近重复的 IoU 阈值")
        p.add_argument("--allow-unknown", action="store_true",
                       help="未知标签名只警告不剔除（默认剔除，保护数据集）")
    args = ap.parse_args(argv)

    json_dir = _resolve(args.json_dir)
    if not json_dir or not json_dir.is_dir():
        print(f"JSON 目录不存在：{json_dir}")
        return 1
    if not list(json_dir.glob("*.json")):
        print(f"未找到 *.json：{json_dir}")
        return 1

    report = scan_dir(json_dir, strict=not args.allow_unknown,
                      min_side=args.min_side, extreme_ratio=args.extreme_ratio,
                      iou_thr=args.iou_thr)

    md = report_markdown(report)
    if args.report:
        rp = _resolve(args.report)
        rp.parent.mkdir(parents=True, exist_ok=True)
        rp.write_text(md, encoding="utf-8")
    if args.csv:
        write_csv(report, _resolve(args.csv))
    print(md)

    if args.cmd == "emit":
        if not args.labels_out:
            print("emit 需要 --labels-out")
            return 1
        out = _resolve(args.labels_out)
        n = emit_labels(report, out)
        print(f"\n已写出 {n} 个标签文件 -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
