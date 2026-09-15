from pathlib import Path

from split_dataset import assign_folds, validate_no_leakage, write_yaml


def _row(name: str, source: str, cls: int) -> dict:
    return {"image_rel": f"{source}/{name}", "source_folder": source, "classes": str(cls),
            "has_label": True, "has_positive": True}


def test_no_source_folder_appears_in_two_folds():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(200)]
    split = assign_folds(rows, (0.8, 0.1, 0.1), seed=42)
    assert validate_no_leakage(split, rows) == []


def test_all_images_are_assigned_exactly_once():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(120)]
    split = assign_folds(rows, (0.8, 0.1, 0.1), seed=42)
    assigned = [n for fold in ("train", "val", "test") for n in split[fold]]
    assert sorted(assigned) == sorted(r["image_rel"] for r in rows)


def test_same_seed_is_reproducible():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(120)]
    assert assign_folds(rows, (0.8, 0.1, 0.1), seed=42) == assign_folds(rows, (0.8, 0.1, 0.1), seed=42)


def test_different_seed_changes_assignment():
    rows = [_row(f"img{i}.jpg", f"src{i // 10}", i % 3) for i in range(120)]
    assert assign_folds(rows, (0.8, 0.1, 0.1), seed=1) != assign_folds(rows, (0.8, 0.1, 0.1), seed=2)


def test_val_covers_every_present_class_when_possible():
    # 6 个来源各含 3 个类别，val 至少应出现全部 3 个类别
    rows = []
    for s in range(6):
        for c in range(3):
            for k in range(5):
                rows.append(_row(f"s{s}_c{c}_{k}.jpg", f"src{s}", c))
    split = assign_folds(rows, (0.6, 0.2, 0.2), seed=42)
    val_rows = [r for r in rows if r["image_rel"] in set(split["val"])]
    present = {int(r["classes"]) for r in val_rows}
    assert present == {0, 1, 2}


def test_no_fold_is_empty():
    rows = []
    for s in range(9):
        for c in range(4):
            for k in range(4):
                rows.append(_row(f"s{s}_c{c}_{k}.jpg", f"src{s}", c))
    split = assign_folds(rows, (0.7, 0.15, 0.15), seed=7)
    assert split["train"] and split["val"] and split["test"]


def test_validate_no_leakage_detects_violation():
    rows = [_row("a.jpg", "srcX", 0)]
    rel = rows[0]["image_rel"]
    split = {"train": [rel], "val": [rel], "test": []}
    assert validate_no_leakage(split, rows) != []


def test_validate_no_leakage_detects_unassigned():
    rows = [_row("a.jpg", "srcX", 0)]
    split = {"train": [], "val": [], "test": []}
    assert validate_no_leakage(split, rows) != []


def test_assign_folds_preserves_subdirectory(tmp_path):
    """返回的键必须保留子目录层级，否则不同来源的同名帧会互相覆盖。"""
    rows = [
        {"image_rel": "route_A_src00/IMG_0001.jpg", "source_folder": "route_A_src00",
         "classes": "0", "has_label": True, "has_positive": True},
        {"image_rel": "route_A_src01/IMG_0001.jpg", "source_folder": "route_A_src01",
         "classes": "0", "has_label": True, "has_positive": True},
    ]
    split = assign_folds(rows, (0.5, 0.25, 0.25), seed=1)
    all_rel = [x for fold in ("train", "val", "test") for x in split[fold]]
    assert len(set(all_rel)) == 2  # 两个同名文件不冲突
    assert all("/" in x for x in all_rel)


def test_write_yaml_emits_absolute_native_paths(tmp_path, monkeypatch):
    """划分清单必须写绝对原生路径，否则 Ultralytics 会找不到标签。

    两点原因：Ultralytics 从 CWD 解析相对路径；img2label_paths() 在 Windows 上
    用 os.sep 拼 ``\\images\\`` -> ``\\labels\\``，正斜杠路径无法匹配。
    """
    import split_dataset as sd

    monkeypatch.setattr(sd, "DATASET_DIR", tmp_path)
    monkeypatch.setattr(sd, "YAML_PATH", tmp_path / "pg.yaml")
    monkeypatch.setattr(sd, "DATASETS_DIR", tmp_path)

    split = {"train": ["src0/a.jpg"], "val": ["src1/b.jpg"], "test": ["src2/c.jpg"]}
    write_yaml(split, ["cls0", "cls1"])

    line = (tmp_path / "train.txt").read_text(encoding="utf-8").strip()
    assert Path(line).is_absolute()
    assert line == str(tmp_path / "images" / "src0" / "a.jpg")
    assert "/" not in line  # Windows 上必须是反斜杠，否则 label 路径推导失败

    yaml_text = (tmp_path / "pg.yaml").read_text(encoding="utf-8")
    assert "nc: 2" in yaml_text
