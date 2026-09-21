"""单来源兜底划分的行为。

真实场景就是当前这份数据：一次实地拍摄 44 张 trashbin 照片，只有一个
source_folder。分组防泄漏划分无从下手（全进 train），训练因为空 val 跑不起来。
"""
import pytest

from single_source import SingleSourceSplitError, single_source_folds


def _rels(n):
    return [f"trashbin/bin ({i}).jpg" for i in range(1, n + 1)]


def test_realistic_44_images_splits_into_three_nonempty_folds():
    """就是本次跑不起来的那份数据：44 张、单来源。"""
    folds = single_source_folds(_rels(44), (0.8, 0.1, 0.1))
    assert len(folds["train"]) == 36
    assert len(folds["val"]) == 4
    assert len(folds["test"]) == 4


def test_all_images_are_used_exactly_once():
    folds = single_source_folds(_rels(44), (0.8, 0.1, 0.1))
    everything = folds["train"] + folds["val"] + folds["test"]
    assert sorted(everything) == sorted(_rels(44))
    assert len(everything) == len(set(everything))


def test_folds_do_not_overlap():
    folds = single_source_folds(_rels(44), (0.8, 0.1, 0.1))
    s = {k: set(v) for k, v in folds.items()}
    assert not s["train"] & s["val"]
    assert not s["train"] & s["test"]
    assert not s["val"] & s["test"]


def test_val_is_spread_across_the_whole_timeline_not_clustered():
    """等间隔取样的意义：val 不该全落在首尾某一小段。"""
    folds = single_source_folds(_rels(40), (0.8, 0.1, 0.1))
    order = {r: i for i, r in enumerate(sorted(_rels(40)))}
    pos = sorted(order[r] for r in folds["val"])
    gaps = [b - a for a, b in zip(pos, pos[1:])]
    assert max(gaps) <= 4 * (40 / len(pos))      # 间隔均匀，无大空洞


def test_various_sizes_always_produce_a_nonempty_val():
    """训练能跑起来的前提：val 永远非空。"""
    for n in range(30, 61):
        folds = single_source_folds(_rels(n), (0.8, 0.1, 0.1))
        assert folds["val"], f"n={n} 时 val 为空"
        assert folds["test"], f"n={n} 时 test 为空"
        assert folds["train"], f"n={n} 时 train 为空"


def test_too_few_images_raises_instead_of_returning_empty_fold():
    with pytest.raises(SingleSourceSplitError):
        single_source_folds(_rels(2), (0.8, 0.1, 0.1))


def test_error_message_states_the_image_count():
    with pytest.raises(SingleSourceSplitError, match="共 2 张"):
        single_source_folds(_rels(2), (0.8, 0.1, 0.1))


def test_more_val_ratio_gives_more_val():
    a = single_source_folds(_rels(50), (0.9, 0.05, 0.05))
    b = single_source_folds(_rels(50), (0.7, 0.2, 0.1))
    assert len(b["val"]) > len(a["val"])


def test_returns_plain_lists_sorted_within_each_fold():
    folds = single_source_folds(_rels(44), (0.8, 0.1, 0.1))
    for v in folds.values():
        assert v == sorted(v)
