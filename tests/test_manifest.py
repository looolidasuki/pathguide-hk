import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from make_manifest import parse_source_meta, read_label_summary  # noqa: E402


def test_parse_source_meta_detects_route_a():
    meta = parse_source_meta("route_A_20260920_tsk_footbridge")
    assert meta["route"] == "route_A"


def test_parse_source_meta_detects_route_b():
    meta = parse_source_meta("route_B_20260922_central_bridge")
    assert meta["route"] == "route_B"


def test_parse_source_meta_unknown_route():
    meta = parse_source_meta("misc_photos")
    assert meta["route"] == "unknown"


def test_parse_source_meta_detects_photo_capture():
    meta = parse_source_meta("route_A_photos_20260920")
    assert meta["capture"] == "photo"


def test_parse_source_meta_defaults_to_video():
    meta = parse_source_meta("route_A_20260920_tsk_footbridge")
    assert meta["capture"] == "video"


def test_read_label_summary_counts_boxes_and_classes(tmp_path):
    label = tmp_path / "a.txt"
    label.write_text("0 0.5 0.5 0.2 0.2\n3 0.1 0.1 0.05 0.05\n0 0.7 0.7 0.1 0.1\n", encoding="utf-8")
    n_boxes, classes = read_label_summary(label)
    assert n_boxes == 3
    assert classes == [0, 3]


def test_read_label_summary_empty_file_is_zero_boxes(tmp_path):
    label = tmp_path / "empty.txt"
    label.write_text("", encoding="utf-8")
    assert read_label_summary(label) == (0, [])


def test_read_label_summary_missing_file(tmp_path):
    assert read_label_summary(tmp_path / "nope.txt") == (-1, [])
