"""单来源数据集端到端走通划分。

这是本次真实故障的回归测试：一次实地拍摄 44 张照片只有一个 source_folder，
分组防泄漏划分把 44 张全丢进 train，val/test 为空，训练脚本报
「划分产物缺失或为空：...val.txt」就停了——错误信息完全没指出真实原因。
"""
import csv
import json
from pathlib import Path

import split_dataset as S


def _make_dataset(root: Path, n: int = 44, source: str = "trashbin") -> None:
    """造一个单来源数据集：n 张图 + 同名标签 + manifest。"""
    img_dir = root / "images" / source
    lbl_dir = root / "labels" / source
    img_dir.mkdir(parents=True)
    lbl_dir.mkdir(parents=True)
    for i in range(1, n + 1):
        (img_dir / f"bin ({i}).jpg").write_bytes(b"x")
        (lbl_dir / f"bin ({i}).txt").write_text("7 0.5 0.5 0.2 0.2", encoding="utf-8")
    rows = [{
        "image_rel": f"{source}/bin ({i}).jpg",
        "source_folder": source,
        "route": "unknown",
        "capture": "photo",
        "has_label": "True",
        "has_positive": "True",
        "n_boxes": "1",
        "classes": "7",
    } for i in range(1, n + 1)]
    manifest = root / "manifest.csv"
    new = not manifest.exists()
    with manifest.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        if new:
            w.writeheader()
        w.writerows(rows)


def test_single_source_dataset_gets_a_usable_split(tmp_path):
    ds = tmp_path / "dataset"
    _make_dataset(ds)
    split = S.run_split(dataset_dir=ds, ratios=(0.8, 0.1, 0.1), seed=42)
    assert len(split["train"]) == 36
    assert len(split["val"]) == 4
    assert len(split["test"]) == 4


def test_single_source_split_is_flagged_so_metrics_are_not_overclaimed(tmp_path):
    """必须留下机器可读的标记：这份划分同源，指标偏乐观。"""
    ds = tmp_path / "dataset"
    _make_dataset(ds)
    split = S.run_split(dataset_dir=ds, ratios=(0.8, 0.1, 0.1), seed=42)
    assert split["single_source"] is True
    assert "泄漏" in split["single_source_note"]


def test_multi_source_dataset_does_not_set_the_single_source_flag(tmp_path):
    ds = tmp_path / "dataset"
    _make_dataset(ds, n=10, source="src_a")
    _make_dataset(ds, n=10, source="src_b")
    split = S.run_split(dataset_dir=ds, ratios=(0.8, 0.1, 0.1), seed=42)
    assert split.get("single_source") is False


def test_split_writes_lists_and_yaml(tmp_path):
    ds = tmp_path / "dataset"
    _make_dataset(ds)
    S.run_split(dataset_dir=ds, ratios=(0.8, 0.1, 0.1), seed=42)
    for fold in ("train", "val", "test"):
        listing = ds / f"{fold}.txt"
        assert listing.exists(), f"{fold}.txt 未写出"
        assert listing.read_text(encoding="utf-8").strip(), f"{fold}.txt 为空"
    payload = json.loads((ds / "split.json").read_text(encoding="utf-8"))
    assert payload["counts"]["val"] == 4


def test_too_small_single_source_dataset_reports_clearly(tmp_path, capsys):
    ds = tmp_path / "dataset"
    _make_dataset(ds, n=2)
    rc = S.run_split(dataset_dir=ds, ratios=(0.8, 0.1, 0.1), seed=42)
    out = capsys.readouterr().out
    assert rc == 1
    assert "共 2 张" in out


def test_empty_fold_detection_reports_which_fold(tmp_path):
    ds = tmp_path / "dataset"
    ds.mkdir()
    (ds / "train.txt").write_text("a.jpg", encoding="utf-8")
    (ds / "val.txt").write_text("", encoding="utf-8")
    (ds / "test.txt").write_text("b.jpg", encoding="utf-8")
    problems = S.check_split_files(ds)
    assert len(problems) == 1
    assert "val" in problems[0]
