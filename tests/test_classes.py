import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
ALIASES_PATH = REPO_ROOT / "configs" / "class_aliases.json"

EXPECTED_GROUPS = ["footbridge", "obstacle", "guide", "indoor", "classifier", "train_only"]
N_CLASSES = 24

# v1（16 类）时的 id -> name_en，用于锁定「天桥专项类从未变动」这一不变量。
# 改动这些会让既有标注数据错位，因此用测试硬性保护。
LEGACY_V1_ID0_5 = [
    "footbridge_entrance",
    "stairs",
    "escalator_outdoor",
    "elevator",
    "ramp",
    "footbridge_railing",
]


@pytest.fixture(scope="module")
def classes():
    with CLASSES_PATH.open(encoding="utf-8") as f:
        return json.load(f)["classes"]


@pytest.fixture(scope="module")
def aliases():
    with ALIASES_PATH.open(encoding="utf-8") as f:
        return json.load(f)["classes"]


# ---- 结构 ----

def test_class_count_is_24(classes):
    assert len(classes) == N_CLASSES


def test_ids_are_contiguous_from_zero(classes):
    assert [c["id"] for c in classes] == list(range(N_CLASSES))


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


# ---- 索引稳定性（最重要：保护既有标注数据）----

def test_id_0_to_5_unchanged_since_v1(classes):
    """天桥专项类 id 0-5 自 v1 起从未变动。

    这是硬不变量：一旦变动，既有标注数据的索引全部错位，
    且训练时不会报错（只会让 mAP 莫名偏低）。
    """
    got = [c["name_en"] for c in classes if c["id"] < 6]
    assert got == LEGACY_V1_ID0_5


def test_id_stability_declared_matches(classes):
    with CLASSES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    assert doc["id_stability"]["stable_since_v1"] == [0, 1, 2, 3, 4, 5]


def test_version_is_2_with_history(classes):
    with CLASSES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    assert doc["version"] == 2
    assert len(doc["history"]) >= 2
    assert doc["history"][-1]["version"] == 2


def test_umbrella_class_removed(classes):
    """伞类 street_obstacle 已删除，内容拆为具体类。"""
    assert "street_obstacle" not in [c["name_en"] for c in classes]


def test_new_obstacle_classes_present(classes):
    names = {c["name_en"] for c in classes}
    for n in ("bin", "bollard", "traffic_cone", "barrier_water",
              "bicycle", "scooter", "cart_trolley"):
        assert n in names, n


def test_deferred_batch_b_not_in_classes(classes):
    """B 档类别不得出现在正式类别表里。"""
    with CLASSES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    deferred = set(doc["deferred_batch_b"]["classes"])
    assert not (deferred & {c["name_en"] for c in classes})


# ---- 别名表与类别表一致性 ----

def test_alias_ids_match_classes(classes, aliases):
    assert [a["id"] for a in aliases] == [c["id"] for c in classes]


def test_alias_names_match_classes(classes, aliases):
    for c, a in zip(classes, aliases):
        assert a["name_en"] == c["name_en"], c["id"]
        assert a["name_zh"] == c["name_zh"], c["id"]


def test_train_only_class_is_not_announced(classes):
    train_only = [c for c in classes if c["group"] == "train_only"]
    assert len(train_only) == 1
    assert train_only[0]["name_en"] == "ambiguous_vertical"
    assert train_only[0]["announced"] is False


def test_all_p0_classes_are_announced(classes):
    for c in classes:
        if c["priority"] == "P0" and c["group"] != "train_only":
            assert c["announced"] is True


def test_ambiguous_vertical_never_from_vlm(aliases):
    a = next(x for x in aliases if x["name_en"] == "ambiguous_vertical")
    assert a.get("never_from_vlm") is True
    assert a.get("verify_query") is None


def test_every_verifiable_class_has_gdin_threshold(aliases):
    """每个可检测的类别都要有 gdin_threshold——实测各类分值分布差异极大，
    统一阈值必然误检与漏检并存。"""
    for a in aliases:
        if a.get("never_from_vlm"):
            assert a.get("gdin_threshold") is None
        else:
            t = a.get("gdin_threshold")
            assert isinstance(t, (int, float)) and 0.0 < t <= 1.0, a["name_en"]


def test_out_of_taxonomy_candidates_exist():
    with ALIASES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    words = doc["out_of_taxonomy_candidates"]["words"]
    assert len(words) >= 10
    assert all(w == w.lower() for w in words)
