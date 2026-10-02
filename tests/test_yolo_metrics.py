"""逐类指标到类名的映射。

这个映射写错过两次，且两次都**不报错、只是给出一张错表**：
`r.names` 是 data.yaml 的类别数（18），`r.box.p` 只覆盖 val 里有实例的类（3），
用 names 的下标去索引 box.p 就会错位或越界。

最危险的不是越界（会炸），而是**长度恰好相等时它靠巧合工作**——
旧模型 3 类、val 也是 3 类时两个长度都是 3，于是错误被掩盖了很久，
换到 18 类数据集才暴露。所以这里把长度一致性也钉死。
"""
from __future__ import annotations

import pytest

from yolo_metrics import map_per_class_metrics


NAMES18 = {i: f"c{i}" for i in range(18)}


def test_用_ap_class_index_把指标对回正确的类():
    """只有 3 个类在 val 里有实例（索引 0/1/2），必须对到 c0/c1/c2。"""
    out = map_per_class_metrics(
        NAMES18,
        p=[0.76, 1.00, 0.86], r=[0.70, 0.94, 0.94],
        ap50=[0.82, 0.99, 0.97], ap=[0.55, 0.45, 0.70],
        ap_class_index=[0, 1, 2], instances=[242, 2, 16],
    )
    assert list(out) == ["c0", "c1", "c2"]
    assert out["c1"]["mAP50"] == 0.99
    assert out["c2"]["instances"] == 16


def test_稀疏类别索引也能对_不是从0开始():
    """val 里可能只有中间某几个类有实例，例如索引 5 和 9。"""
    out = map_per_class_metrics(
        NAMES18,
        p=[0.5, 0.6], r=[0.4, 0.7], ap50=[0.45, 0.65], ap=[0.3, 0.4],
        ap_class_index=[5, 9],
    )
    assert list(out) == ["c5", "c9"]
    assert out["c9"]["class_index"] == 9


def test_长度不一致必须报错而不是给出错表():
    """这条守着旧写法：names 18 项、指标 3 项，用 names 下标取就会错。

    正确的行为是**明确报错**，因为静默地给出错位的表比报错危险得多。
    """
    with pytest.raises(ValueError, match="ap_class_index 长度"):
        map_per_class_metrics(
            NAMES18, p=[0.1, 0.2, 0.3], r=[0.1, 0.2, 0.3],
            ap50=[0.1, 0.2, 0.3], ap=[0.1, 0.2, 0.3],
            ap_class_index=[0, 1],          # 只有 2 个，但指标有 3 个
        )


def test_不给_ap_class_index_时按恒等映射并校验长度():
    out = map_per_class_metrics(
        {0: "a", 1: "b"}, p=[0.1, 0.2], r=[0.3, 0.4],
        ap50=[0.5, 0.6], ap=[0.7, 0.8],
    )
    assert list(out) == ["a", "b"]
    # 但若长度对不上就必须报错，不能默默错位
    with pytest.raises(ValueError):
        map_per_class_metrics(
            NAMES18, p=[0.1, 0.2], r=[0.3, 0.4], ap50=[0.5, 0.6], ap=[0.7, 0.8],
        )


def test_各数组长度必须一致():
    with pytest.raises(ValueError, match="长度不一致"):
        map_per_class_metrics(
            NAMES18, p=[0.1], r=[0.1, 0.2], ap50=[0.1], ap=[0.1],
            ap_class_index=[0],
        )


def test_越界的类别索引必须报错():
    with pytest.raises(ValueError, match="超出类别表范围"):
        map_per_class_metrics(
            NAMES18, p=[0.1], r=[0.1], ap50=[0.1], ap=[0.1],
            ap_class_index=[99],
        )


def test_列表形式的_names_也能用():
    out = map_per_class_metrics(
        ["a", "b", "c"], p=[0.1, 0.2], r=[0.1, 0.2],
        ap50=[0.1, 0.2], ap=[0.1, 0.2], ap_class_index=[2, 0],
    )
    assert list(out) == ["c", "a"]


def test_instances_按类别索引而不是槽位索引():
    """nt_per_class 按类别索引，所以稀疏情况下不能直接用槽位 k 去取。

    实测踩过：索引 [5,9] 时若用 instances[k]，会取到第 0/1 个类的实例数，
    于是「本类只有 2 个实例」这类关键数字会张冠李戴。
    """
    inst = [0] * 18
    inst[5] = 111
    inst[9] = 222
    out = map_per_class_metrics(
        NAMES18, p=[0.5, 0.6], r=[0.5, 0.6], ap50=[0.5, 0.6], ap=[0.5, 0.6],
        ap_class_index=[5, 9], instances=inst,
    )
    assert out["c5"]["instances"] == 111
    assert out["c9"]["instances"] == 222
