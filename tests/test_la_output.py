import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "pipeline"))

from la_output import exists_for, has_any_positive, parse  # noqa: E402


# ---- 真实实测样本 ----

POS = "<ref>bench</ref><box><0><9><863><995></box><|im_end|>"
NEG = "<ref>bench</ref><box>None</box><|im_end|>"
ECHO = "<ref>Late</ref><box><0><0><864><1000></box><|im_end|>"


def test_positive_box_parsed():
    d = parse(POS)
    assert len(d) == 1
    assert d[0]["ref"] == "bench"
    assert d[0]["exists"] is True
    assert d[0]["bbox"] == pytest.approx([0.0, 0.009, 0.863, 0.995], abs=1e-6)


def test_none_inside_box_is_negative():
    """核心陷阱：否定时 <box> 标签仍然存在，内容才是 None。"""
    d = parse(NEG)
    assert len(d) == 1
    assert d[0]["ref"] == "bench"
    assert d[0]["exists"] is False
    assert d[0]["bbox"] is None


def test_none_content_does_not_become_coordinates():
    """若误把 None 当数值解析，会产生垃圾框。必须返回 None。"""
    assert parse("<box>None</box>")[0]["bbox"] is None
    assert parse("<box>none</box>")[0]["bbox"] is None
    assert parse("<box> null </box>")[0]["bbox"] is None
    assert parse("<box>N/A</box>")[0]["bbox"] is None


def test_echoed_prompt_is_preserved_but_flagged():
    """回显噪声保留原文以便排查，但坐标仍可解析。"""
    d = parse(ECHO)
    assert d[0]["ref"] == "Late"
    assert d[0]["exists"] is True


def test_has_any_positive_distinguishes():
    assert has_any_positive(POS) is True
    assert has_any_positive(NEG) is False
    assert has_any_positive("") is False


# ---- 多目标与多种坐标格式 ----

def test_one_ref_can_own_multiple_boxes():
    """实测格式：一个 <ref> 管辖其后所有 <box>，表示「多个同类目标」。

    真实的整图输出就是这个形态（一张图里两个长椅）：
        <ref>bench</ref><box>A</box><box>B</box>
    """
    raw = "<ref>bench</ref><box><315><724><477><999></box><box><368><682><476><969></box>"
    d = parse(raw)
    assert len(d) == 2
    assert all(x["ref"] == "bench" for x in d)
    assert all(x["exists"] for x in d)


def test_multiple_refs_each_own_their_boxes():
    raw = ("<ref>bench</ref><box><315><724><477><999></box>"
           "<box><368><682><476><969></box>"
           "<ref>bin</ref><box><322><613><399><758></box>")
    d = parse(raw)
    assert [x["ref"] for x in d] == ["bench", "bench", "bin"]
    assert all(x["exists"] for x in d)


def test_ref_with_no_box_means_absent():
    """ref 后没有任何 box -> 该类别不存在（而非解析失败）。"""
    raw = "<ref>bench</ref><ref>bin</ref><box><100><100><200><200></box>"
    d = parse(raw)
    assert d[0] == {"ref": "bench", "bbox": None, "exists": False}
    assert d[1]["ref"] == "bin" and d[1]["exists"] is True


def test_bare_boxes_without_ref_are_kept():
    """没有 ref 的裸 box 也要保留，便于排查模型异常输出。"""
    d = parse("<box><0><0><500><500></box>")
    assert len(d) == 1 and d[0]["ref"] == "" and d[0]["exists"] is True


def test_comma_separated_coordinates():
    d = parse("<ref>bench</ref><box>100, 200, 300, 400</box>")
    assert d[0]["bbox"] == pytest.approx([0.1, 0.2, 0.3, 0.4])


def test_normalized_coordinates_not_divided():
    d = parse("<ref>bench</ref><box>0.1 0.2 0.3 0.4</box>")
    assert d[0]["bbox"] == pytest.approx([0.1, 0.2, 0.3, 0.4])


def test_coordinates_clamped_to_unit_range():
    d = parse("<ref>bench</ref><box><-50><-20><1200><1100></box>")
    assert d[0]["bbox"] == pytest.approx([0.0, 0.0, 1.0, 1.0])


def test_degenerate_box_is_none():
    d = parse("<ref>bench</ref><box><500><500><500><500></box>")
    assert d[0]["bbox"] is None and d[0]["exists"] is False


def test_garbage_returns_empty():
    assert parse("no markup here") == []
    assert parse("") == []
    assert parse(None) == []


# ---- 指定类别的存在性判定 ----

def test_exists_for_matching_ref():
    assert exists_for(POS, "bench") is True
    assert exists_for(NEG, "bench") is False


def test_exists_for_unmentioned_ref_returns_none():
    """输出里没提到该类时应返回 None（无法判定），而不是 False。"""
    assert exists_for(POS, "footbridge entrance") is None


def test_exists_for_case_insensitive():
    assert exists_for(POS, "Bench") is True


def test_exists_for_uses_taxonomy_aliases():
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "pipeline"))
    from label_taxonomy import LabelTaxonomy

    tax = LabelTaxonomy()
    raw = "<ref>rubbish bin</ref><box><100><100><300><400></box>"
    # 用同义说法查询应能命中（都归到 street_obstacle=7）
    assert exists_for(raw, "trash bin", taxonomy=tax) is True


def test_exists_for_no_markup_returns_none():
    assert exists_for("nothing", "bench") is None
