"""X-AnyLabeling JSON -> 数据集 的读写与校验。

这个模块存在的理由：X-AnyLabeling 的 JSON 是**唯一的最终标注真相**
（人工改过框之后，data/dataset/labels/ 里的预标注已经过期）。所以在
转回训练格式之前，必须先能可靠地读出 shape，并把坏框挑出来。
"""
import json

import pytest

import xlabel_io as X


# ---------------------------------------------------------------- 读 JSON

def _write(tmp_path, name, payload, image_name=None, size=(200, 100)):
    """写一个最小可用的 X-AnyLabeling JSON（不写图片）。"""
    data = {
        "version": "0.4.43",
        "flags": {},
        "shapes": payload,
        "imagePath": image_name or f"{name}.jpg",
        "imageData": None,
        "imageHeight": size[1],
        "imageWidth": size[0],
    }
    p = tmp_path / f"{name}.json"
    p.write_text(json.dumps(data), encoding="utf-8")
    return p


def _rect(label, x1, y1, x2, y2):
    return {"label": label, "text": "", "points": [[x1, y1], [x2, y2]],
            "shape_type": "rectangle", "group_id": None, "flags": {}}


def test_rect_xyxy_reads_two_point_rectangle():
    shape = _rect("bin", 10, 20, 30, 60)
    assert X.rect_xyxy(shape) == (10.0, 20.0, 30.0, 60.0)


def test_rect_xyxy_is_none_for_empty_points():
    # 这正是 shape.py:161 断言的那类 shape（画框途中 points 为空）
    assert X.rect_xyxy({"label": "bin", "points": []}) is None


def test_rect_xyxy_is_none_for_polygon():
    poly = {"label": "bin", "points": [[0, 0], [10, 0], [10, 10]],
            "shape_type": "polygon"}
    assert X.rect_xyxy(poly) is None


def test_read_shapes_skips_broken_shapes_without_raising(tmp_path):
    p = _write(tmp_path, "a", [_rect("bin", 1, 1, 5, 5), {"label": "bin", "points": []}])
    shapes, size = X.read_shapes(p)
    assert len(shapes) == 1
    assert shapes[0]["label"] == "bin"
    assert size == (200, 100)


def test_read_shapes_returns_image_size_from_json(tmp_path):
    p = _write(tmp_path, "a", [], size=(640, 480))
    _, size = X.read_shapes(p)
    assert size == (640, 480)


# ------------------------------------------------------------ 类别解析

def test_resolve_label_accepts_canonical_name():
    # bin 在 classes.txt 里是第 7 行
    assert X.resolve_label("bin") == 7


def test_resolve_label_is_none_for_unknown_name():
    assert X.resolve_label("made_up_thing") is None


def test_resolve_label_rejects_unknown_instead_of_guessing():
    # ambiguous_vertical 是 train_only 占位类，不许进数据集
    assert X.resolve_label("ambiguous_vertical") is None


def test_resolve_label_accepts_case_and_space_variants():
    assert X.resolve_label("Cart Trolley") == 13
    assert X.resolve_label("cart-trolley") == 13


# -------------------------------------------------------------- 框校验

def test_normal_box_has_no_failures():
    assert X.box_failures((10, 20, 30, 60), (200, 100), min_side=2.0) == []


def test_degenerate_box_fails():
    assert "degenerate" in X.box_failures((10, 20, 10, 60), (200, 100), min_side=2.0)


def test_negative_coordinate_fails():
    assert "oob" in X.box_failures((-3, 20, 30, 60), (200, 100), min_side=2.0)


def test_box_beyond_image_fails():
    assert "oob" in X.box_failures((10, 20, 30, 160), (200, 100), min_side=2.0)


def test_tiny_box_fails_min_side():
    assert "tiny" in X.box_failures((10, 20, 11, 60), (200, 100), min_side=2.0)


def test_box_touching_edge_exactly_is_ok():
    assert X.box_failures((0, 0, 200, 100), (200, 100), min_side=2.0) == []


# --- 退化框 vs 细长框：竖直细杆（栏杆、杆）应当只 warn 不 fail ---

def test_thin_tall_box_is_warned_not_failed():
    warn = []
    fails = X.box_failures((10, 20, 12, 90), (200, 100), min_side=2.0,
                           extreme_ratio=8.0, warnings_out=warn)
    assert "degenerate" not in fails
    assert "extreme_ratio" in warn


def test_squat_wide_box_is_warned_not_failed():
    w = []
    X.box_failures((10, 20, 190, 22), (200, 100), min_side=2.0,
                   extreme_ratio=8.0, warnings_out=w)
    assert "extreme_ratio" in w


# ------------------------------------------------- 同名同类近重复检测

def test_near_duplicate_is_detected_at_high_iou():
    pairs = X.find_duplicates([(0.0, "bin", (0, 0, 50, 50)),
                               (1.0, "bin", (1, 1, 51, 51))], iou_thr=0.8)
    assert len(pairs) == 1
    assert pairs[0][:2] == (0, 1)
    # 交 49*49=2401，并 2500+2500-2401=2599
    assert pairs[0][2] == pytest.approx(2401 / 2599, abs=1e-6)


def test_different_labels_at_same_spot_is_not_a_duplicate():
    assert X.find_duplicates([(0.0, "bin", (0, 0, 50, 50)),
                              (1.0, "bollard", (0, 0, 50, 50))], iou_thr=0.8) == []


def test_low_overlap_is_not_a_duplicate():
    assert X.find_duplicates([(0.0, "bin", (0, 0, 50, 50)),
                              (1.0, "bin", (60, 60, 100, 100))], iou_thr=0.8) == []


def test_duplicate_check_uses_confidence_tiebreak_order():
    # 前一个 conf 更高 -> 保留前者、删后者
    pairs = X.find_duplicates([(0.9, "bin", (0, 0, 50, 50)),
                               (0.3, "bin", (1, 1, 51, 51))], iou_thr=0.8)
    assert pairs[0][:2] == (0, 1)


# --------------------------------------------------------- YOLO 写回

def test_to_yolo_line_converts_to_normalized_center():
    line = X.to_yolo_line(7, (10.0, 20.0, 30.0, 60.0), (200, 100), precision=6)
    assert line == "7 0.100000 0.400000 0.100000 0.400000"


def test_to_yolo_line_clamps_tiny_epsilon_overflow():
    # 手工画的框可能 1e-9 越界，写回去要夹紧而不是产出 >1 的坐标
    line = X.to_yolo_line(7, (-1e-9, 20.0, 200.0000001, 60.0), (200, 100), precision=6)
    parts = line.split()
    assert all(0.0 <= float(v) <= 1.0 for v in parts[1:])


# ------------------------------------------------------------- 汇总

def test_class_counts_counts_instances_per_class():
    boxes = [(0.5, "bin", (0, 0, 10, 10)), (0.5, "bin", (20, 0, 30, 10)),
             (0.5, "pedestrian", (40, 0, 50, 10))]
    assert X.class_counts(boxes) == {"bin": 2, "pedestrian": 1}


# ------------------------------------------------- 目录级：汇总与回写

def _make_dir(tmp_path):
    """两个 JSON 的迷你复核目录：一个正常，一个含各种坏框。"""
    d = tmp_path / "xtest"
    d.mkdir()
    _write(d, "img_a", [_rect("bin", 10, 20, 30, 60),
                        _rect("pedestrian", 100, 10, 120, 90)])
    _write(d, "img_b", [_rect("bin", 10, 20, 30, 60),        # 与下面那个近似重复
                        _rect("bin", 11, 21, 31, 61),        # -> 被剔除
                        _rect("bin", 10, 70, 10, 90),        # 退化
                        _rect("bin", 150, 70, 300, 90),      # 越界
                        _rect("made_up", 40, 20, 60, 60)])   # 未知类
    return d


def test_scan_reports_unknown_labels(tmp_path):
    report = X.scan_dir(_make_dir(tmp_path), strict=True)
    assert report.unknown_labels == {"made_up": 1}


def test_scan_reports_fatal_boxes_with_file_and_index(tmp_path):
    report = X.scan_dir(_make_dir(tmp_path), strict=True)
    problems = {(b.file, b.failures[0]) for b in report.boxes if b.failures}
    assert ("img_b.json", "degenerate") in problems
    assert ("img_b.json", "oob") in problems


def test_scan_counts_duplicate_pairs(tmp_path):
    report = X.scan_dir(_make_dir(tmp_path), strict=True)
    assert report.n_duplicates == 1


def test_scan_dir_with_strict_false_keeps_unknown_labels_as_boxes(tmp_path):
    """strict=False 时未知类只警告不剔除，交给人工分拣。"""
    report = X.scan_dir(_make_dir(tmp_path), strict=False)
    kept_unknown = [b for b in report.kept if b.label == "made_up"]
    assert len(kept_unknown) == 1
    assert "unknown_label" in kept_unknown[0].warnings


def test_emit_writes_one_txt_per_image_with_mirrored_names(tmp_path):
    src = _make_dir(tmp_path)
    out = tmp_path / "labels"
    report = X.scan_dir(src, strict=True)
    n = X.emit_labels(report, out)
    assert n == 2
    # img_b 里合法的只剩 1 个 bin（重复的、退化的、越界的、未知类都被剔除）
    assert len((out / "img_b.txt").read_text(encoding="utf-8").splitlines()) == 1
    assert len((out / "img_a.txt").read_text(encoding="utf-8").splitlines()) == 2
    assert (out / "img_a.txt").read_text(encoding="utf-8").splitlines()[0] == \
        "7 0.100000 0.400000 0.100000 0.400000"


def test_degenerate_box_is_not_counted_as_a_duplicate(tmp_path):
    """退化框已判死，不该再重复计数成 near_duplicate。"""
    src = tmp_path / "xtest"
    src.mkdir()
    _write(src, "img_e", [_rect("bin", 10, 20, 10, 60), _rect("bin", 10, 20, 10, 61)])
    report = X.scan_dir(src, strict=True)
    assert report.n_duplicates == 0
    assert all("near_duplicate" in b.failures or "degenerate" in b.failures
               for b in report.boxes)


def test_emit_drops_the_lower_confidence_duplicate(tmp_path):
    src = tmp_path / "xtest"
    src.mkdir()
    # 前面那个 conf 高 -> 保留；后面那个 conf 低 -> 删
    _write(src, "img_c", [_rect("bin", 0, 0, 50, 50), _rect("bin", 1, 1, 51, 51)])
    report = X.scan_dir(src, strict=True)
    # 人工标注没有置信度，两个都是 1.0；按「保留先出现的」处理，必须只留 1 个
    out = tmp_path / "labels"
    X.emit_labels(report, out)
    assert len((out / "img_c.txt").read_text(encoding="utf-8").splitlines()) == 1


def test_emit_writes_empty_file_for_image_with_no_valid_boxes(tmp_path):
    src = tmp_path / "xtest"
    src.mkdir()
    _write(src, "img_d", [])
    report = X.scan_dir(src, strict=True)
    out = tmp_path / "labels"
    X.emit_labels(report, out)
    assert (out / "img_d.txt").exists()
    assert (out / "img_d.txt").read_text(encoding="utf-8") == ""


def test_report_markdown_lists_per_class_instance_counts(tmp_path):
    report = X.scan_dir(_make_dir(tmp_path), strict=True)
    md = X.report_markdown(report)
    assert "| bin |" in md
    assert "img_b.json" in md


# ------------------------------------------------------------------ CLI

def test_cli_check_writes_report_and_touches_no_labels(tmp_path, capsys):
    src = _make_dir(tmp_path)
    report_path = tmp_path / "out" / "check.md"
    csv_path = tmp_path / "out" / "boxes.csv"
    labels_out = tmp_path / "labels_should_not_appear"
    rc = X.main(["check", "--json-dir", str(src), "--report", str(report_path),
                 "--csv", str(csv_path)])
    assert rc == 0
    assert report_path.exists()
    assert csv_path.exists()
    assert not labels_out.exists()
    text = report_path.read_text(encoding="utf-8")
    assert "img_b.json" in text                      # 问题框明细里点名到文件
    assert "img_a.json" in csv_path.read_text(encoding="utf-8-sig")   # CSV 覆盖全部文件


def test_cli_emit_writes_labels_and_refuses_unknown_labels_by_default(tmp_path):
    src = _make_dir(tmp_path)
    out = tmp_path / "labels"
    rc = X.main(["emit", "--json-dir", str(src), "--labels-out", str(out)])
    assert rc == 0
    assert sorted(p.name for p in out.glob("*.txt")) == ["img_a.txt", "img_b.txt"]
    assert (out / "img_a.txt").read_text(encoding="utf-8").startswith("7 ")


def test_cli_emit_refuses_when_no_json_found(tmp_path, capsys):
    empty = tmp_path / "empty"
    empty.mkdir()
    rc = X.main(["emit", "--json-dir", str(empty), "--labels-out",
                 str(tmp_path / "labels")])
    assert rc == 1
    assert "未找到" in capsys.readouterr().out
