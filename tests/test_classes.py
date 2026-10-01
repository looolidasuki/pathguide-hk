import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSES_PATH = REPO_ROOT / "configs" / "classes.json"
ALIASES_PATH = REPO_ROOT / "configs" / "class_aliases.json"

EXPECTED_GROUPS = ["footbridge", "obstacle", "guide", "indoor", "classifier", "train_only"]
N_CLASSES = 48

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

# v2（24 类）时 id 6-22 的 name_en。v3 扩到 48 类时只允许动 id 13（改名，不改槽位）
# 与 id 23（删除没有标注的占位类），其余必须逐字不变——这些槽位上已有标注数据。
LEGACY_V2_ID6_22 = [
    "pedestrian", "bin", "bollard", "traffic_cone", "barrier_water",
    "bicycle", "scooter", "cart_trolley", "step",
    "tactile_paving", "zebra_crossing",
    "glass_door", "door", "escalator_indoor", "sign_pictogram", "glass_door_indoor",
    "shop_front",
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


def test_id_6_to_22_unchanged_since_v2_except_push_cart(classes):
    """v3 扩表时，id 6-22 只允许把 13 由 cart_trolley 改名为 push_cart。

    **这是保护既有标注的核心断言。** 这些槽位上有真标注（bin 88 框、pedestrian 30、
    push_cart 2 等），槽位一挪，标注就全体错位，而训练只会表现为 mAP 偏低。
    所以除了那一个约定好的改名，其余必须逐字相同。
    """
    got = [c["name_en"] for c in classes if 6 <= c["id"] <= 22]
    assert got[13 - 6] == "push_cart", "id 13 应当已改名为 push_cart"
    expected = list(LEGACY_V2_ID6_22)
    expected[13 - 6] = "push_cart"
    assert got == expected


def test_new_classes_occupy_23_to_47(classes):
    """v3 新增的 25 类占 id 23-47，且 id 23 是复用原本没有标注的占位槽。"""
    new = [c for c in classes if c["id"] >= 23]
    assert len(new) == 25
    assert [c["id"] for c in new] == list(range(23, 48))
    assert new[0]["name_en"] == "fork_in_road"


def test_reused_slot_is_declared(classes):
    """复用 id 23 这件事必须显式记录在案。

    「复用了一个曾经有别的含义的 id」是最容易造成历史标注错位的一类改动，
    因此要求它在 id_stability.reused_slots 里写明理由与核查结论。
    """
    with CLASSES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    reused = doc["id_stability"].get("reused_slots", {})
    assert "23" in reused
    assert "ambiguous_vertical" in reused["23"]


def test_id_stability_declared_matches(classes):
    with CLASSES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    assert doc["id_stability"]["stable_since_v1"] == [0, 1, 2, 3, 4, 5]
    assert doc["id_stability"]["stable_since_v2"] == list(range(23))


def test_version_is_3_with_history(classes):
    with CLASSES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    assert doc["version"] == 3
    assert len(doc["history"]) >= 3
    assert doc["history"][-1]["version"] == 3


def test_umbrella_class_removed(classes):
    """伞类 street_obstacle 已删除，内容拆为具体类。"""
    assert "street_obstacle" not in [c["name_en"] for c in classes]


def test_new_obstacle_classes_present(classes):
    names = {c["name_en"] for c in classes}
    for n in ("bin", "bollard", "traffic_cone", "barrier_water",
              "bicycle", "scooter", "push_cart"):
        assert n in names, n


def test_split_classes_present(classes):
    """v3 把原 cart_trolley 拆成了四类，四个都要在表里。"""
    names = {c["name_en"] for c in classes}
    for n in ("push_cart", "hand_truck", "pallet", "pushchair"):
        assert n in names, n
    assert "cart_trolley" not in names, "旧名不应残留，否则 Dart 侧会生成两个相同的显示名"


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


def test_placeholder_class_is_gone(classes, aliases):
    """v3 删掉了训练期占位类 ambiguous_vertical（id 23 让给 fork_in_road）。

    它当年存在的理由是「分不清是楼梯还是扶梯时给个兜底类」。删它的理由：
    分类任务里保留一个语义为「不知道」的类，会持续吸收本该被丢弃的模糊框，
    而这些框对训练是噪声、对用户毫无信息量。真遇到分不清的垂直设施，
    正确做法是**不产生框**，而不是产生一个「不知道」的框。
    """
    names = {c["name_en"] for c in classes}
    assert "ambiguous_vertical" not in names
    assert not any(c.get("never_from_vlm") for c in aliases), (
        "never_from_vlm 这个机制当前没有类别使用；若将来重新引入占位类，"
        "请连同 tests/test_label_taxonomy.py 的相应断言一起加回来"
    )
    assert not [c for c in classes if c["group"] == "train_only"]


def test_all_p0_classes_are_announced(classes):
    for c in classes:
        if c["priority"] == "P0" and c["group"] != "train_only":
            assert c["announced"] is True


def test_every_verifiable_class_has_gdin_threshold(aliases):
    """每个可检测的类别都要有 gdin_threshold——实测各类分值分布差异极大，
    统一阈值必然误检与漏检并存。"""
    for a in aliases:
        if a.get("never_from_vlm"):
            assert a.get("gdin_threshold") is None
        else:
            t = a.get("gdin_threshold")
            assert isinstance(t, (int, float)) and 0.0 < t <= 1.0, a["name_en"]


def test_unmeasured_thresholds_are_declared(aliases):
    """v3 新增的类还没有数据，其阈值没有实测依据——必须显式记录待重标。

    不记的话，零样本阶段这些类的框数会被当成可信数字，
    而实际上阈值是猜的：这正是「模型看着能用、实际不行」的典型来源。
    """
    doc = json.loads(ALIASES_PATH.read_text(encoding="utf-8"))
    declared = set(doc["unmeasured_thresholds"]["ids"])
    assert declared == set(range(23, 48)), "v3 新增的 25 类都应列入待重标"


def test_out_of_taxonomy_words_are_not_already_classes(classes, aliases):
    """表外候选词不能是已经是类别的词。

    否则「类别发现」会把已知类别当成新发现，反复灌进 out_of_taxonomy.csv
    要人决策——v3 扩表时就有 7 个词（tree/cardboard/table/chair/utility box/
    lamp post/banner）处于这种状态。
    """
    doc = json.loads(ALIASES_PATH.read_text(encoding="utf-8"))
    words = {w.lower() for w in doc["out_of_taxonomy_candidates"]["words"]}
    class_names = {c["name_en"].replace("_", " ") for c in classes}
    alias_words = set()
    for a in aliases:
        for alias in a.get("la_aliases", []):
            alias_words.add(alias.lower())
        for p in a.get("yolo_world_prompts", []):
            alias_words.add(p.lower())
    overlap = words & (class_names | alias_words)
    assert not overlap, f"这些词已经是类别或类别别名，不该留在表外候选里：{sorted(overlap)}"


def test_out_of_taxonomy_candidates_exist():
    with ALIASES_PATH.open(encoding="utf-8") as f:
        doc = json.load(f)
    words = doc["out_of_taxonomy_candidates"]["words"]
    assert len(words) >= 10
    assert all(w == w.lower() for w in words)
