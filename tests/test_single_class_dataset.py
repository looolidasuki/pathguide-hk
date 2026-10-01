"""单类数据集构建：标签索引重写。

这是最容易静默出错的一步——类别索引被重写错时，训练照跑、指标照出，
只是类别全错。所以逐个用例钉死。
"""
import csv
import json
from pathlib import Path

import pytest

import build_single_class_dataset as B


def _write_dataset(root: Path, images, labels: dict[str, str]) -> None:
    """images: [(rel, bytes)]；labels: {rel_image_str: text}"""
    (root / "images").mkdir(parents=True, exist_ok=True)
    (root / "labels").mkdir(parents=True, exist_ok=True)
    rows = []
    for rel, _ in images:
        p = root / "images" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
        rows.append({
            "image_rel": rel.as_posix(),
            "source_folder": rel.parts[0] if len(rel.parts) > 1 else "all",
            "route": "unknown", "capture": "video",
            "has_label": "True", "has_positive": "True",
            "n_boxes": "1", "classes": "7",
        })
    with (root / "manifest.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    for rel, text in labels.items():
        lp = root / "labels" / Path(rel).with_suffix(".txt")
        lp.parent.mkdir(parents=True, exist_ok=True)
        lp.write_text(text, encoding="utf-8")


# ------------------------------------------------------------ 标签重写

def test_keeps_lines_of_the_target_class():
    out = B.rewrite_label("7 0.5 0.5 0.2 0.2", keep_id=7)
    assert out == ["0 0.500000 0.500000 0.200000 0.200000"]


def test_drops_other_classes():
    out = B.rewrite_label("6 0.5 0.5 0.2 0.2\n7 0.1 0.1 0.1 0.1", keep_id=7)
    assert len(out) == 1
    assert out[0].startswith("0 ")


def test_keeps_multiple_lines_of_target_class():
    text = "7 0.1 0.1 0.1 0.1\n7 0.2 0.2 0.2 0.2\n7 0.3 0.3 0.3 0.3"
    assert len(B.rewrite_label(text, keep_id=7)) == 3


def test_class_index_becomes_zero_not_stays():
    """最关键的一条：索引必须变成 0。若保持原值，nc=1 的模型会把它当越界类丢弃。"""
    out = B.rewrite_label("7 0.5 0.5 0.2 0.2", keep_id=7)
    assert out[0].split()[0] == "0"


def test_coordinates_are_preserved_exactly():
    out = B.rewrite_label("7 0.123456 0.654321 0.111111 0.222222", keep_id=7)
    assert out[0].split()[1:] == ["0.123456", "0.654321", "0.111111", "0.222222"]


def test_empty_and_blank_lines_are_ignored():
    assert B.rewrite_label("\n\n   \n", keep_id=7) == []


def test_malformed_lines_are_skipped_not_crashed():
    assert B.rewrite_label("nonsense\n7 0.5 0.5\n7 0.5 0.5 0.2 0.2", keep_id=7) == [
        "0 0.500000 0.500000 0.200000 0.200000",
    ]


def test_class_id_written_as_float_is_accepted():
    # 有些导出工具会写成 "7.0"
    assert len(B.rewrite_label("7.0 0.5 0.5 0.2 0.2", keep_id=7)) == 1


def test_does_not_confuse_similar_ids():
    """id 7 与 17、70 不能混。"""
    text = "17 0.5 0.5 0.2 0.2\n70 0.5 0.5 0.2 0.2\n7 0.5 0.5 0.2 0.2"
    out = B.rewrite_label(text, keep_id=7)
    assert len(out) == 1


# ------------------------------------------------------------ 端到端

def test_build_creates_mirrored_structure(tmp_path, monkeypatch):
    src = tmp_path / "src"
    _write_dataset(src, [(Path("trashbin/a.jpg"), b"")], {"trashbin/a.jpg": "7 0.5 0.5 0.2 0.2"})
    monkeypatch.setattr(B, "SRC_DATASET", src)
    monkeypatch.setattr(B, "REPO_ROOT", tmp_path)

    out = B.build(class_id=7, name="bin")
    assert (out / "images" / "trashbin" / "a.jpg").exists()
    assert (out / "labels" / "trashbin" / "a.txt").read_text(encoding="utf-8") == \
        "0 0.500000 0.500000 0.200000 0.200000"


def test_build_writes_single_class_table_with_original_id(tmp_path, monkeypatch):
    src = tmp_path / "src"
    _write_dataset(src, [(Path("trashbin/a.jpg"), b"")], {"trashbin/a.jpg": "7 0.5 0.5 0.2 0.2"})
    monkeypatch.setattr(B, "SRC_DATASET", src)
    monkeypatch.setattr(B, "REPO_ROOT", tmp_path)

    out = B.build(class_id=7, name="bin")
    table = json.loads((out / "classes.json").read_text(encoding="utf-8"))
    assert len(table["classes"]) == 1
    assert table["classes"][0]["name_en"] == "bin"
    # 保留原 id，App 侧才能把模型输出的 0 映射回类别表里的 7
    assert table["classes"][0]["original_id"] == 7


def test_build_keeps_images_with_no_target_as_negatives(tmp_path, monkeypatch):
    """只有行人没有垃圾桶的图应保留为负样本，对降低误报有用。"""
    src = tmp_path / "src"
    _write_dataset(
        src,
        [(Path("trashbin/a.jpg"), b""), (Path("trashbin/b.jpg"), b"")],
        {"trashbin/a.jpg": "7 0.5 0.5 0.2 0.2", "trashbin/b.jpg": "6 0.5 0.5 0.2 0.2"},
    )
    monkeypatch.setattr(B, "SRC_DATASET", src)
    monkeypatch.setattr(B, "REPO_ROOT", tmp_path)

    out = B.build(class_id=7, name="bin")
    assert (out / "labels" / "trashbin" / "b.txt").read_text(encoding="utf-8") == ""
    with (out / "manifest.csv").open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    neg = [r for r in rows if r["has_positive"] == "False"]
    assert len(neg) == 1 and neg[0]["image_rel"].endswith("b.jpg")


def test_build_reports_counts(tmp_path, monkeypatch, capsys):
    src = tmp_path / "src"
    _write_dataset(src, [(Path("trashbin/a.jpg"), b"")],
                   {"trashbin/a.jpg": "7 0.1 0.1 0.1 0.1\n6 0.2 0.2 0.2 0.2"})
    monkeypatch.setattr(B, "SRC_DATASET", src)
    monkeypatch.setattr(B, "REPO_ROOT", tmp_path)

    B.build(class_id=7, name="bin")
    out = capsys.readouterr().out
    assert "保留标注框 1 个" in out
    assert "丢弃其他类别的框 1 个" in out


def test_load_class_name_reads_config():
    assert B.load_class_name(7) == "bin"
    assert B.load_class_name(6) == "pedestrian"


def test_load_class_name_rejects_unknown_id():
    with pytest.raises(ValueError, match="不在 configs/classes.json"):
        B.load_class_name(999)

