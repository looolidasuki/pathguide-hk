"""跨模型文本标签归一。

问题：YOLO-World 与 LocateAnything 输出的都是自由文本（"rubbish bin" / "trash bin"
/ "garbage can"），而 YOLO 标签只能用类别 id。两个模型的框要能比较，必须先归一到同一空间。

设计原则：**宁可判为未知，也不强行归类。**
强行归类会产生错误标注，而错误标注在训练时不报错，只会让 mAP 莫名偏低——
本文件的所有阈值都服务于"不确定就说不确定"。

归一顺序（从强到弱）：
    1. 精确匹配别名（含简单复数归并）
    2. 词集合包含关系（Jaccard ≥ token_overlap_threshold）
    3. 字符相似度（difflib ratio ≥ similarity_threshold）
    都不中 -> None（未知类别，不参与匹配）
"""
from __future__ import annotations

import json
import re
from difflib import SequenceMatcher
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]   # scripts/pipeline/ -> 仓库根
ALIASES_PATH = REPO_ROOT / "configs" / "class_aliases.json"

_PUNCT = re.compile(r"[^\w\s]")
_WS = re.compile(r"\s+")


def normalize_text(s: str) -> str:
    s = (s or "").lower().strip()
    s = _PUNCT.sub(" ", s)
    s = _WS.sub(" ", s)
    return s.strip()


def _singularize(token: str) -> str:
    """粗糙的复数字尾归并。只处理常见情况，不求语言学正确。"""
    if len(token) > 3 and token.endswith("ies"):
        return token[:-3] + "y"
    if len(token) > 3 and token.endswith("es") and not token.endswith("ses"):
        return token[:-2]
    if len(token) > 2 and token.endswith("s") and not token.endswith("ss"):
        return token[:-1]
    return token


def tokenize(s: str) -> set[str]:
    return {_singularize(t) for t in normalize_text(s).split() if t}


class LabelTaxonomy:
    def __init__(self, path: Path = ALIASES_PATH):
        with path.open(encoding="utf-8") as f:
            data = json.load(f)
        self.classes = sorted(data["classes"], key=lambda c: c["id"])
        m = data.get("matching", {})
        self.token_overlap_threshold = float(m.get("token_overlap_threshold", 0.6))
        self.similarity_threshold = float(m.get("similarity_threshold", 0.72))

        # 歧义别名：文本本身无法区分同名的户外/室内类（玻璃门 9/14、扶梯 2/13）。
        # 仅凭文字归类等于抛硬币，故这些说法一律返回未决。
        raw_ambiguous = m.get("ambiguous_aliases", {})
        self.ambiguous: dict[str, list[int]] = {
            normalize_text(k): v for k, v in raw_ambiguous.items() if k != "note"
        }

        # 别名 -> id（精确匹配表）。歧义说法不进表，避免字典顺序决定归类。
        self._exact: dict[str, int] = {}
        for c in self.classes:
            for alias in c.get("la_aliases", []):
                key = normalize_text(alias)
                if key in self.ambiguous:
                    continue
                self._exact[key] = c["id"]
            base = normalize_text(c["name_en"])
            if base not in self.ambiguous:
                self._exact[base] = c["id"]
            spaced = normalize_text(c["name_en"].replace("_", " "))
            if spaced not in self.ambiguous:
                self._exact[spaced] = c["id"]

        # 词集合索引：id -> 别名 token 集合（同样排除歧义说法）
        self._token_sets: list[tuple[int, set[str]]] = []
        for c in self.classes:
            if c.get("never_from_vlm"):
                continue
            aliases = list(c.get("la_aliases", [])) + [c["name_en"].replace("_", " ")]
            for alias in aliases:
                if normalize_text(alias) in self.ambiguous:
                    continue
                self._token_sets.append((c["id"], tokenize(alias)))

    # ---- 查询 ----

    def name(self, cid: int) -> str:
        return self.classes[cid]["name_en"]

    def verify_query(self, cid: int) -> str | None:
        """VLM 裁剪验证该用哪个提问词。

        **绝不能用笼统的类别名。** 实测（垃圾桶 52 个候选框）：用伞类名
        'street_obstacle' 提问只确认 48%，换成 'rubbish bin' 确认 96%、
        'bin' 确认 100%。用类别名去问会把一半正确框判成误检。

        返回 None 表示该类不该由 VLM 验证（如 ambiguous_vertical，
        它的定义就是「无法判定」，让 VLM 验证自相矛盾）。
        """
        c = self.classes[cid]
        q = c.get("verify_query")
        if q is None:
            return None
        if c.get("never_from_vlm"):
            return None
        return str(q)

    def yolo_world_prompts(self) -> list[str]:
        """YOLO-World 的类别集合（可同时设入的文本 prompt 列表）。"""
        return [p for c in self.classes for p in c.get("yolo_world_prompts", [])]

    def prompt_to_id(self) -> dict[str, int]:
        """YOLO-World 用的是固定 prompt 列表，索引即 id，这里给出映射以便校验。"""
        out: dict[str, int] = {}
        for c in self.classes:
            for p in c.get("yolo_world_prompts", []):
                out[normalize_text(p)] = c["id"]
        return out

    def vlm_class_list(self) -> str:
        """给 VLM 的待查类别清单（用英文名，逗号分隔）。"""
        return ", ".join(c["name_zh"] + f" ({c['name_en']})" for c in self.classes)

    # ---- 归一 ----

    def is_ambiguous(self, text: str) -> list[int] | None:
        """若该说法是歧义的，返回候选 id 列表；否则返回 None。"""
        return self.ambiguous.get(normalize_text(text))

    def lookup(self, text: str) -> int | None:
        """把自由文本标签归一到类别 id；无法确定或存在歧义则返回 None。

        歧义（如 "glass door" 同属 9/14）返回 None 是刻意设计：
        上层可以用场景信息裁决，而错误的归类会污染数据集且不报错。
        """
        n = normalize_text(text)
        if not n:
            return None

        # 0) 歧义说法：文本层面无法判定
        if n in self.ambiguous:
            return None

        # 1) 精确匹配
        if n in self._exact:
            return self._exact[n]

        toks = tokenize(text)
        if not toks:
            return None

        # 2) 词集合包含（Jaccard）
        best_id, best_score = None, 0.0
        for cid, alias_toks in self._token_sets:
            if not alias_toks:
                continue
            inter = len(toks & alias_toks)
            union = len(toks | alias_toks)
            score = inter / union if union else 0.0
            if score > best_score:
                best_id, best_score = cid, score
        if best_score >= self.token_overlap_threshold:
            return best_id

        # 3) 字符相似度
        best_id2, best_sim = None, 0.0
        for alias, cid in self._exact.items():
            sim = SequenceMatcher(None, n, alias).ratio()
            if sim > best_sim:
                best_id2, best_sim = cid, sim
        if best_sim >= self.similarity_threshold:
            return best_id2

        return None


def iou_xyxy(a: tuple[float, float, float, float],
             b: tuple[float, float, float, float]) -> float:
    ix1, iy1 = max(a[0], b[0]), max(a[1], b[1])
    ix2, iy2 = min(a[2], b[2]), min(a[3], b[3])
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0:
        return 0.0
    area_a = max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
    area_b = max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0
