"""把 ultralytics 的逐类指标正确地对回类名。

## 为什么单独抽出来

这个映射写错过**两次**，而且两次都**不报错、只是给出错误的表**：

    for i, name in r.names.items():
        r.box.p[i]          # ← 错

`r.names` 是 **data.yaml 的类别数**（poc5 是 18），
而 `r.box.p` 只覆盖 **val 里真的有实例的类**（poc5 是 3）。
两个长度不等时抛 IndexError 还算幸运；**长度相等时（例如都是 3 的旧模型）
它恰好工作**——那才是真正危险的：一个靠巧合正确、在换数据集时才炸的写法。

正确映射是 `r.box.ap_class_index`（给出每个指标槽位对应的类别索引）。

抽成纯函数是为了能在不装 ultralytics、不加载模型的情况下单元测试。
"""
from __future__ import annotations

from typing import Any, Iterable, Mapping, Sequence

__all__ = ["map_per_class_metrics", "ap_index_of"]


def ap_index_of(metrics: Any) -> list[int]:
    """取「每个指标槽位对应的类别索引」。

    优先用 box.ap_class_index；缺失时退回 ap_class_index；
    都没有就认为是恒等映射（旧版本 ultralytics）——但**不静默**，
    由调用方通过返回长度与 names 的比较自行判断。
    """
    box = getattr(metrics, "box", None)
    for obj in (box, metrics):
        if obj is None:
            continue
        idx = getattr(obj, "ap_class_index", None)
        if idx is not None:
            return [int(i) for i in idx]
    return []


def map_per_class_metrics(
    names: Mapping[int, str] | Sequence[str],
    p: Sequence[float],
    r: Sequence[float],
    ap50: Sequence[float],
    ap: Sequence[float],
    ap_class_index: Iterable[int] | None = None,
    instances: Sequence[int] | None = None,
    round_to: int | None = 4,
) -> dict[str, dict[str, Any]]:
    """把逐类指标数组对回类名。

    - `ap_class_index` 为空时视作恒等映射（旧行为），但会校验长度一致——
      长度不一致就抛错，而不是给出错误的表。
    - `instances`（nt_per_class）按**类别索引**索引，不是按槽位索引。
    """
    if isinstance(names, Mapping):
        n_items = len(names)
        get_name = lambda i: names[i]
    else:
        n_items = len(names)
        get_name = lambda i: names[i]

    idx = [int(i) for i in ap_class_index] if ap_class_index else list(range(len(p)))

    if not ap_class_index and n_items != len(p):
        # 没有 ap_class_index 时只能假定恒等映射，而恒等映射**只在
        # 「类别数 == 指标数」时成立**。不成立就说明我们无从知道
        # 这些指标对应哪些类——此时必须报错，静默错位比报错危险得多。
        # （这条正是能抓住最初那个 bug 的守卫：names 18 项、指标 3 项。）
        raise ValueError(
            f"未提供 ap_class_index 且类别表有 {n_items} 项、逐类指标有 {len(p)} 项，"
            f"无法确定指标对应哪些类。请传 r.box.ap_class_index；"
            f"不要用 r.names 的下标去索引 box.p——两者长度本来就可能不等。")

    if len(idx) != len(p):
        raise ValueError(
            f"ap_class_index 长度 {len(idx)} 与逐类指标长度 {len(p)} 不一致；"
            f"不能用 r.names 的下标去索引 box.p——两者长度本来就可能不等"
            f"（names 是 data.yaml 的类别数，box.p 只覆盖 val 里有实例的类）")
    if not (len(p) == len(r) == len(ap50) == len(ap)):
        raise ValueError("p / r / ap50 / ap 长度不一致")

    out: dict[str, dict[str, Any]] = {}
    for k, ci in enumerate(idx):
        if not (0 <= ci < n_items):
            raise ValueError(f"ap_class_index 里的 {ci} 超出类别表范围 [0,{n_items})")
        def rnd(v: float) -> float:
            return round(float(v), round_to) if round_to is not None else float(v)
        out[get_name(ci)] = {
            "class_index": ci,
            "precision": rnd(p[k]),
            "recall": rnd(r[k]),
            "mAP50": rnd(ap50[k]),
            "mAP50_95": rnd(ap[k]),
            "instances": (int(instances[ci])
                          if instances is not None and ci < len(instances) else None),
        }
    return out
