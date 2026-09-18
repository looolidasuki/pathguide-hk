import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "pipeline"))

from label_taxonomy import LabelTaxonomy, iou_xyxy, normalize_text, tokenize  # noqa: E402


@pytest.fixture(scope="module")
def tax():
    return LabelTaxonomy()


# ---- 文本归一 ----

def test_normalize_lowercases_and_strips_punct():
    assert normalize_text("  Rubbish-Bin!  ") == "rubbish bin"


def test_normalize_collapses_whitespace():
    assert normalize_text("a   trash\n bin") == "a trash bin"


def test_singularize_handles_plural():
    assert tokenize("benches") == tokenize("bench")


def test_singularize_handles_ies():
    assert "puppy" in tokenize("puppies")


def test_singularize_keeps_double_s():
    assert "glass" in tokenize("glass")


# ---- 精确匹配 ----

def test_exact_alias_match(tax):
    assert tax.lookup("stairs") == 1
    assert tax.lookup("pedestrian") == 6


def test_rubbish_bin_maps_to_its_own_class(tax):
    """v2 起垃圾桶是独立类别 bin(7)，不再是伞类 street_obstacle 的一部分。"""
    for t in ("rubbish bin", "trash bin", "litter bin", "garbage can", "waste bin", "dustbin", "bin"):
        assert tax.lookup(t) == 7, t
    assert tax.name(7) == "bin"


def test_bench_is_unknown_not_misclassified(tax):
    # 「bench」不在类别表里（属 B 档），应判为未知而非错误归类
    assert tax.lookup("a bench") is None


def test_pedestrian_aliases(tax):
    assert tax.lookup("person") == 6
    assert tax.lookup("people") == 6
    assert tax.lookup("pedestrians") == 6


def test_name_en_with_underscores_maps_to_itself(tax):
    assert tax.lookup("footbridge_entrance") == 0
    assert tax.lookup("footbridge entrance") == 0


def test_tactile_paving_variants(tax):
    assert tax.lookup("yellow tactile paving") == 15
    assert tax.lookup("blind guide path") == 15


def test_ambiguous_glass_door_returns_none(tax):
    """户外/室内玻璃门无法从文本区分，必须返回未决而不是猜一个。

    猜错会污染数据集且训练时不报错——这是刻意的保守设计。
    """
    assert tax.lookup("glass door") is None
    assert tax.is_ambiguous("glass door") == [17, 21]


def test_ambiguous_escalator_returns_none(tax):
    assert tax.lookup("escalator") is None
    assert tax.is_ambiguous("escalator") == [2, 19]


def test_disambiguated_forms_still_work(tax):
    """带限定词的说法应能明确归类。"""
    assert tax.lookup("indoor glass door") == 21
    assert tax.lookup("outdoor escalator") == 2
    assert tax.lookup("mall escalator") == 19


def test_empty_string_is_unknown(tax):
    assert tax.lookup("") is None
    assert tax.lookup("   ") is None


def test_nonsense_is_unknown(tax):
    # 关键安全属性：不确定必须返回 None，不能强行归类
    assert tax.lookup("zzz qqq xyzzy") is None


def test_ambiguous_vertical_is_marked_never_from_vlm(tax):
    assert any(c.get("never_from_vlm") for c in tax.classes if c["id"] == 23)


# ---- VLM 验证提问词（踩过的最贵的坑）----

def test_verify_query_uses_specific_object_name_not_umbrella_class(tax):
    """*绝不能用笼统的类别名做验证提问*。

    实测：垃圾桶 52 个候选框，用伞类名 'street_obstacle' 提问只确认 48%，
    换成 'bin' 确认 100%。用类别名问会把一半正确框判成误检。
    """
    assert tax.verify_query(7) == "bin"


def test_verify_query_is_none_for_ambiguous_vertical(tax):
    """该类的定义就是「无法判定」，让 VLM 验证自相矛盾，必须返回 None。"""
    assert tax.verify_query(23) is None


def test_verify_query_present_for_all_verifiable_classes(tax):
    for c in tax.classes:
        if c.get("never_from_vlm"):
            assert tax.verify_query(c["id"]) is None
        else:
            q = tax.verify_query(c["id"])
            assert isinstance(q, str) and q.strip(), c["name_en"]


def test_verify_query_escalator_variants_are_disambiguated(tax):
    """扶梯的户外/室内对必须用带限定词的说法，否则两者无法区分。"""
    assert "outdoor" in tax.verify_query(2)
    assert "indoor" in tax.verify_query(19)


# ---- prompt 映射 ----

def test_yolo_world_prompts_are_unique_and_mapped(tax):
    mapping = tax.prompt_to_id()
    prompts = tax.yolo_world_prompts()
    assert len(prompts) == len(set(normalize_text(p) for p in prompts))
    assert all(normalize_text(p) in mapping for p in prompts)


def test_yolo_world_prompt_ids_are_in_range(tax):
    for cid in tax.prompt_to_id().values():
        assert 0 <= cid < len(tax.classes)


def test_vlm_class_list_mentions_all_classes(tax):
    s = tax.vlm_class_list()
    for c in tax.classes:
        assert c["name_zh"] in s


# ---- IoU ----

def test_iou_identical_is_one():
    assert iou_xyxy((0, 0, 10, 10), (0, 0, 10, 10)) == pytest.approx(1.0)


def test_iou_disjoint_is_zero():
    assert iou_xyxy((0, 0, 10, 10), (20, 20, 30, 30)) == 0.0


def test_iou_half_overlap():
    # 面积 100 与 100，交 50，并 150 -> 1/3
    assert iou_xyxy((0, 0, 10, 10), (5, 0, 15, 10)) == pytest.approx(50 / 150)


def test_iou_degenerate_box_is_zero():
    assert iou_xyxy((5, 5, 5, 5), (0, 0, 10, 10)) == 0.0
