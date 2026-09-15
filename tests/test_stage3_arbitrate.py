import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "pipeline"))

from stage3_arbitrate import area, build_priority, resolve_conflicts  # noqa: E402


@pytest.fixture(scope="module")
def tax():
    from label_taxonomy import LabelTaxonomy

    return LabelTaxonomy()


def _det(cid: int, bbox, conf: float = 0.5, **kw) -> dict:
    return {"class_id": cid, "bbox": list(bbox), "conf": conf, **kw}


# ---- 面积 ----

def test_area_of_unit_box():
    assert area([0.0, 0.0, 1.0, 1.0]) == pytest.approx(1.0)


def test_area_of_degenerate_box_is_zero():
    assert area([0.5, 0.5, 0.5, 0.5]) == 0.0


# ---- 优先级 ----

def test_umbrella_class_has_lowest_priority(tax):
    prio = build_priority(tax)
    sid = next(c["id"] for c in tax.classes if c["name_en"] == "street_obstacle")
    aid = next(c["id"] for c in tax.classes if c["name_en"] == "ambiguous_vertical")
    sid_prio = prio[sid]
    assert all(prio[c["id"]] < sid_prio
               for c in tax.classes if c["name_en"] not in ("street_obstacle", "ambiguous_vertical"))
    # ambiguous_vertical 是训练专用类，优先级最低
    assert prio[aid] > sid_prio


# ---- 冲突消解 ----

def test_non_overlapping_boxes_all_kept(tax):
    prio = build_priority(tax)
    dets = [_det(3, [0.0, 0.0, 0.2, 0.2]), _det(9, [0.5, 0.5, 0.7, 0.7])]
    kept, merged = resolve_conflicts(dets, prio, 0.55)
    assert len(kept) == 2 and not merged


def test_same_class_overlapping_boxes_are_not_deduped_here(tax):
    """类内重复由第一段的类内 NMS 处理，本段只管跨类。"""
    prio = build_priority(tax)
    dets = [_det(3, [0.0, 0.0, 0.4, 0.4]), _det(3, [0.02, 0.02, 0.42, 0.42])]
    kept, merged = resolve_conflicts(dets, prio, 0.55)
    assert len(kept) == 2 and not merged


def test_cross_class_overlap_keeps_specific_class(tax):
    """具体设施应胜过伞类：elevator(3) 与 street_obstacle(7) 重叠时保留 elevator。"""
    prio = build_priority(tax)
    box = [0.1, 0.1, 0.4, 0.5]
    dets = [_det(7, box, 0.9), _det(3, box, 0.3)]
    kept, merged = resolve_conflicts(dets, prio, 0.55)
    assert len(kept) == 1
    assert kept[0]["class_id"] == 3, "应保留更具体的类别，尽管它置信度更低"
    assert len(merged) == 1
    assert merged[0]["merged_into_class"] == 3


def test_conflict_iou_recorded(tax):
    prio = build_priority(tax)
    dets = [_det(3, [0.0, 0.0, 0.4, 0.4]), _det(7, [0.0, 0.0, 0.4, 0.4])]
    _, merged = resolve_conflicts(dets, prio, 0.55)
    assert merged and merged[0]["conflict_iou"] == pytest.approx(1.0)


def test_below_iou_threshold_not_merged(tax):
    prio = build_priority(tax)
    # IoU = 0.2/0.6 ~= 0.33 < 0.55
    dets = [_det(3, [0.0, 0.0, 0.4, 0.5]), _det(7, [0.2, 0.0, 0.6, 0.5])]
    kept, merged = resolve_conflicts(dets, prio, 0.55)
    assert len(kept) == 2 and not merged


def test_same_class_higher_conf_wins_among_equals(tax):
    """优先级相同时按置信度降序，保留高置信度者。"""
    prio = build_priority(tax)
    box = [0.1, 0.1, 0.4, 0.4]
    dets = [_det(1, box, 0.3), _det(8, box, 0.8)]  # stairs vs step，优先级相同
    kept, _ = resolve_conflicts(dets, prio, 0.55)
    assert len(kept) == 1
    assert kept[0]["conf"] == 0.8


def test_empty_input():
    kept, merged = resolve_conflicts([], {}, 0.55)
    assert kept == [] and merged == []
