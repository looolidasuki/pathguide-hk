"""LocateAnything 输出解析。

实测发现的格式与陷阱（必须按此实现，否则第二段会全线误判）：

    正确输出：<ref>bench</ref><box><0><9><863><995></box><|im_end|>
    否定输出：<ref>bench</ref><box>None</box><|im_end|>          <- 注意 None 在 box 标签**内部**
    回显噪声：<ref>Late</ref><box><0><0><864><1000></box>        <- prompt 片段被当类别名回显

三个关键点：
1. **不能用 "有没有 <box> 标签" 判断存在性**——否定时标签也存在，内容是 `None`。
   （这是实测踩到的陷阱：POS 与 NEG 都含 `<box>`，靠标签存在性判断会 100% 误判。）
2. 坐标有两种写法：嵌套 `<x1><y1><x2><y2>` 或逗号分隔 `x1, y1, x2, y2`，都要支持。
3. 坐标是 **[0, 1000] 归一化**，需除以 1000 转为 [0, 1]。
4. 模型偶尔把 prompt 片段回显成 ref（"Locate all benches." -> `<ref>Late</ref>`）。
   下游用词表校验 ref 是否可信，不在此处硬过滤——保留原文以便排查。
"""
from __future__ import annotations

import re

NEGATIVE_TOKENS = {"none", "null", "nil", "n a", "na", "no"}

_REF = re.compile(r"<ref>(.*?)</ref>", re.DOTALL)
_BOX = re.compile(r"<box>(.*?)</box>", re.DOTALL)
_NUM = re.compile(r"-?\d+(?:\.\d+)?")
_END = re.compile(r"<\|im_end\|>")


def _parse_box_body(body: str) -> list[float] | None:
    """解析 <box> 内部。返回 [0,1] 归一化坐标，或 None 表示否定/不可解析。"""
    text = (body or "").strip()
    if not text:
        return None
    # 否定：内容是 None / null / n/a 等
    flat = re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()
    if flat in NEGATIVE_TOKENS or flat.startswith("none"):
        return None
    nums = [float(x) for x in _NUM.findall(text)]
    if len(nums) < 4:
        return None
    x1, y1, x2, y2 = nums[:4]
    # [0,1000] -> [0,1]；容错处理模型偶尔给出像素值的情况
    if max(x1, y1, x2, y2) > 1.5:
        x1, y1, x2, y2 = x1 / 1000.0, y1 / 1000.0, x2 / 1000.0, y2 / 1000.0
    x1, x2 = sorted((max(0.0, min(1.0, x1)), max(0.0, min(1.0, x2))))
    y1, y2 = sorted((max(0.0, min(1.0, y1)), max(0.0, min(1.0, y2))))
    if x2 - x1 <= 0 or y2 - y1 <= 0:
        return None
    return [x1, y1, x2, y2]


def parse(raw: str) -> list[dict]:
    """解析 LocateAnything 的原始输出。

    返回 [{"ref": str, "bbox": [x1,y1,x2,y2] 归一化 或 None, "exists": bool}, ...]

    归属规则（依实测格式）：**一个 `<ref>` 管辖其后直到下一个 `<ref>` 之前的所有 `<box>`。**
    实测样本 `<ref>bench</ref><box>A</box><box>B</box><ref>bin</ref><box>C</box>`
    表示"两个 bench + 一个 bin"，而不是按顺序一一配对。
    """
    if raw is None:
        return []
    text = _END.sub("", str(raw))

    # 按 ref 切段：每段 = (ref 文本, 该段内所有 box 内容)
    segments: list[tuple[str, list[str]]] = []
    cursor = 0
    for m in _REF.finditer(text):
        if segments:
            prev_ref, _ = segments[-1]
            segments[-1] = (prev_ref, [b.group(1) for b in _BOX.finditer(text, cursor, m.start())])
        segments.append((m.group(1).strip(), []))
        cursor = m.end()
    if segments:
        prev_ref, _ = segments[-1]
        segments[-1] = (prev_ref, [b.group(1) for b in _BOX.finditer(text, cursor)])
    else:
        # 没有任何 ref：把裸 box 也保留下来（便于排查），ref 为空
        boxes = [b.group(1) for b in _BOX.finditer(text)]
        if not boxes:
            return []
        return [{"ref": "", "bbox": (bb := _parse_box_body(b)), "exists": bb is not None}
                for b in boxes]

    out: list[dict] = []
    for ref, box_bodies in segments:
        if not box_bodies:
            # 有 ref 无 box：视为该类别不存在
            out.append({"ref": ref, "bbox": None, "exists": False})
            continue
        for body in box_bodies:
            bbox = _parse_box_body(body)
            out.append({"ref": ref, "bbox": bbox, "exists": bbox is not None})
    return out


def has_any_positive(raw: str) -> bool:
    """是否存在至少一个带真实坐标的框（用于裁剪验证的 yes/no 判定）。"""
    return any(d["exists"] for d in parse(raw))


def exists_for(raw: str, class_text: str, taxonomy=None) -> bool | None:
    """针对指定类别的存在性判定。

    返回 True/False；若输出中找不到与 class_text 对应的 ref，返回 None（无法判定，
    而不是猜一个）。taxonomy 非空时会用别名表做匹配，处理 "bin" vs "rubbish bin" 一类差异。
    """
    dets = parse(raw)
    if not dets:
        return None

    def same(a: str, b: str) -> bool:
        if taxonomy is not None:
            ca = taxonomy.lookup(a)
            cb = taxonomy.lookup(b)
            if ca is not None and cb is not None:
                return ca == cb
        return a.strip().lower() == b.strip().lower()

    matched = [d for d in dets if same(d["ref"], class_text)]
    if not matched:
        # 没有匹配到该 ref：若输出里存在其它 ref 的否定项，视为"未提及"而非"不存在"
        return None
    return any(d["exists"] for d in matched)
