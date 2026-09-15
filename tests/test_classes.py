import json
from pathlib import Path

import pytest

CLASSES_PATH = Path(__file__).resolve().parents[1] / "configs" / "classes.json"

EXPECTED_GROUPS = ["footbridge", "obstacle", "guide", "indoor", "train_only"]


@pytest.fixture(scope="module")
def classes():
    with CLASSES_PATH.open(encoding="utf-8") as f:
        return json.load(f)["classes"]


def test_class_count_is_16(classes):
    assert len(classes) == 16


def test_ids_are_contiguous_from_zero(classes):
    assert [c["id"] for c in classes] == list(range(16))


def test_names_en_are_unique(classes):
    names = [c["name_en"] for c in classes]
    assert len(names) == len(set(names))


def test_names_en_are_snake_case_ascii(classes):
    for c in classes:
        assert c["name_en"].isascii()
        assert c["name_en"] == c["name_en"].lower()
        assert " " not in c["name_en"]


def test_every_class_has_chinese_label(classes):
    for c in classes:
        assert c["name_zh"].strip()


def test_groups_are_known(classes):
    for c in classes:
        assert c["group"] in EXPECTED_GROUPS


def test_train_only_class_is_not_announced(classes):
    train_only = [c for c in classes if c["group"] == "train_only"]
    assert len(train_only) == 1
    assert train_only[0]["name_en"] == "ambiguous_vertical"
    assert train_only[0]["announced"] is False


def test_all_p0_classes_are_announced(classes):
    for c in classes:
        if c["priority"] == "P0" and c["group"] != "train_only":
            assert c["announced"] is True


def test_footbridge_group_has_six_classes(classes):
    assert len([c for c in classes if c["group"] == "footbridge"]) == 6
