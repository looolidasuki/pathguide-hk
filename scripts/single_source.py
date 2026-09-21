"""单来源数据集的兜底划分。

## 为什么需要它

`assign_folds` 按 source_folder 分组防泄漏。但「一次实地采集 = 一个文件夹」时
它无从下手：44 张全进 train，val/test 为空，训练直接跑不起来。

这类数据集**无法做真正无泄漏的划分**——同一地点连续拍的相邻帧几乎相同，
无论怎么切都有泄漏。所以这里的定位是**诚实的退路**，不是防泄漏方案：
它按文件名序等间隔取样，让 val 分散在整个采集时段，并在调用方打印
「同源，指标偏乐观」的警告。

样本量不足以支撑独立 val 或 test 时**显式报错**，而不是悄悄给一个空折——
空 val 会让训练跑不起来，空 test 会让评测给出假指标。
"""
from __future__ import annotations


class SingleSourceSplitError(ValueError):
    """样本量不足以在同一个来源内切出独立的 val/test。"""


def single_source_folds(rels: list[str], ratios: tuple[float, float, float],
                        min_fold: int = 1) -> dict[str, list[str]]:
    """单来源等间隔取样划分。

    取法：排序后按步长取样，val 与 test 相位错开，使两者都不集中在某一时段。
    剩余全部归 train。
    """
    rels = sorted(rels)
    n = len(rels)
    # 先给 val/test 向下取整分配，余数全部归 train（train 是唯一不设上限的折）
    n_val = max(min_fold, int(n * ratios[1]))
    n_test = max(min_fold, int(n * ratios[2]))
    n_train = n - n_val - n_test
    if n_train < min_fold:
        raise SingleSourceSplitError(
            f"共 {n} 张，按 ratios={ratios} 切不出 train/val/test 三折"
            f"（至少需要 {3 * min_fold} 张）")

    def sample(k: int, phase: float = 0.0) -> set[int]:
        """从 n 个位置里等间隔取 k 个，phase 用来错开不同折。"""
        if k <= 0:
            return set()
        step = n / k
        return {min(n - 1, int(round(phase + i * step))) for i in range(k)}

    idx_val = sample(n_val)
    idx_test = sample(n_test, phase=n / (2 * max(n_test, 1)))
    # 撞了就把 test 整体后移一格，直到不相交
    guard = 0
    while idx_test & idx_val and guard < n:
        idx_test = {(i + 1) % n for i in idx_test}
        guard += 1

    out = {"train": [], "val": [], "test": []}
    for i, rel in enumerate(rels):
        if i in idx_val:
            out["val"].append(rel)
        elif i in idx_test:
            out["test"].append(rel)
        else:
            out["train"].append(rel)
    return out
