"""匹配精确率比较的纯逻辑。

这段逻辑此前被我手工算过三次——手工算就有算错的风险，而论文里的对比表
必须可复现。所以抽成函数并钉住几个**容易错**的点：

1. 取的是「P 达标里召回最高的那个阈值」，**不是阈值最低的那个**。
   PR 曲线不单调：某个阈值掉到目标以下、下一个又回到目标以上是常见现象，
   按阈值最低取会选到一个精度不达标或召回更低的点。
2. 「网格内达不到目标精度」必须明确报出，不能悄悄返回一个不达标的点
   （那会让读者以为该模型在高精度档也有数）。
3. 某个类在某个阈值没有条目时不能当成 0。
"""
from __future__ import annotations

import pytest

from matched_precision import best_at_target, usable_confs


def mk(entries: dict[str, tuple[float, float]]) -> dict:
    """把 {conf: (P, R)} 变成 compare_at_threshold 的输出形态。"""
    return {conf: {"pedestrian": {"precision": p, "recall": r}}
            for conf, (p, r) in entries.items()}


def test_取达标里召回最高的而不是阈值最低的():
    """PR 曲线不单调时，两者结果不同——这条就是守这一点。

    下面 0.30 处 P=0.80（不达标），0.40 处 P=0.95/R=0.60（达标），
    0.50 处 P=0.96/R=0.50（也达标）。
    达标里召回最高的是 0.40，不是阈值最低的达标点……两者恰好相同，
    所以再构造一个「更低的阈值精度不达标」的情形来区分。
    """
    d = mk({"0.30": (0.80, 0.90),     # 精度不达标，但召回最高
            "0.40": (0.95, 0.60),
            "0.50": (0.96, 0.50)})
    got = best_at_target(d, "pedestrian", 0.90)
    assert got is not None
    assert got[0] == 0.40, f"应取 0.40（达标里召回最高），实际取到 {got[0]}"


def test_非单调时仍取达标里召回最高的():
    # 0.50 达标且召回 0.70；0.60 掉到 0.85（不达标）；0.70 又达标但召回只有 0.40
    d = mk({"0.50": (0.92, 0.70), "0.60": (0.85, 0.65), "0.70": (0.97, 0.40)})
    got = best_at_target(d, "pedestrian", 0.90)
    assert got[0] == 0.50 and got[2] == 0.70


def test_达不到目标时必须返回_None_而不是硬给一个点():
    d = mk({"0.60": (0.90, 0.50), "0.70": (0.94, 0.30)})
    assert best_at_target(d, "pedestrian", 0.99) is None


def test_该类不存在时返回_None():
    d = {"0.70": {"bin": {"precision": 1.0, "recall": 0.5}}}
    assert best_at_target(d, "pedestrian", 0.90) is None


def test_usable_confs_按阈值排序且跳过缺项():
    d = {"0.70": {"pedestrian": {"precision": 0.9, "recall": 0.4}},
         "0.30": {"pedestrian": {"precision": 0.8, "recall": 0.6}},
         "0.50": {"bin": {"precision": 1.0, "recall": 0.9}}}
    got = usable_confs(d, "pedestrian")
    assert [c for c, _, _ in got] == [0.30, 0.70]


def test_恰好等于目标精度算达标():
    """边界：P == target 必须算达标，否则会把刚好达标的点漏掉。"""
    d = mk({"0.65": (0.95, 0.55)})
    got = best_at_target(d, "pedestrian", 0.95)
    assert got is not None and got[2] == 0.55


def test_实跑结果回归_三个模型在三个目标档上的召回():
    """用 artifacts/metrics/stage2_compare.json 的真实结果做回归。

    这几个数字已写进 docs/superpowers/plans/2026-10-02-two-stage-finetune.md，
    所以它们一旦变化就说明脚本或数据有问题，应当报警。
    """
    import json
    from pathlib import Path
    p = Path(__file__).resolve().parents[1] / "artifacts/metrics/stage2_compare.json"
    if not p.exists():
        pytest.skip("artifacts/ 是 gitignore 的构建产物")
    d = json.loads(p.read_text(encoding="utf-8"))
    expect = {
        (0.90, "pg_poc3"): 0.5931, (0.90, "pg_poc5"): 0.5537, (0.90, "pg_stage2"): 0.6405,
        (0.93, "pg_poc3"): 0.5331, (0.93, "pg_poc5"): 0.5165, (0.93, "pg_stage2"): 0.6033,
        (0.95, "pg_poc3"): 0.4793, (0.95, "pg_poc5"): 0.3512, (0.95, "pg_stage2"): 0.5620,
    }
    for (target, run), want in expect.items():
        got = best_at_target(d[run], "pedestrian", target)
        assert got is not None, f"{run} 在 P>={target} 处应有解"
        # JSON 里的精度是 4 位小数，所以容差取 1e-4
        assert abs(got[2] - want) < 1e-4, \
            f"{run} P>={target} 召回应为 {want}，实际 {got[2]}"

    # 这一条同时守着「stage2 在 P>=0.97 档达不到」这个**结论本身**
    assert best_at_target(d["pg_stage2"], "pedestrian", 0.97) is None
    assert best_at_target(d["pg_poc3"], "pedestrian", 0.97) is not None
