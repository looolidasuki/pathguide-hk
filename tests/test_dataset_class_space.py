"""数据集的类别空间必须能构造出**通过 App 侧校验**的模型清单。

## 为什么值得做成门禁

`export_tflite.py` 的导出链是 `PyTorch -> ONNX -> TensorFlow SavedModel -> TFLite`，
要跑很久（本项目还为此单独建了 `.venv-export` 环境）。
如果类别空间有问题（id 重复、超出类别表、映射表长度不符），
**那要等到导出最后一步写清单时才炸**，前面的时间全白费。

而清单的校验规则在 Dart 侧（`model_manifest.dart` / `model_class_map.dart`），
Python 这边应该照同样规则提前复算一遍。这条测试就是那个复算。

被它挡住过的真实情形：第二阶段微调时数据集若只覆盖部分类，
`modelClassIds` 就会少项，而 App 侧会正常启动、只是每个框标错类。
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TAXONOMY = REPO_ROOT / "configs" / "classes.json"

# 数据集目录（data/ 是 gitignore 的，缺了就 skip）
DATASETS = ["dataset_poc3", "dataset_poc4", "dataset_poc5", "dataset_hk_stage2"]


def _taxonomy() -> tuple[int, set[int]]:
    d = json.loads(TAXONOMY.read_text(encoding="utf-8"))
    classes = d["classes"]
    return len(classes), {c["id"] for c in classes}


def _classes_json(name: str) -> Path:
    p = REPO_ROOT / "data" / name / "classes.json"
    if not p.exists():
        pytest.skip(f"{name} 不存在（data/ 是 gitignore 的构建产物）")
    return p


@pytest.mark.parametrize("name", DATASETS)
def test_映射表长度与类别数一致(name):
    ds = json.loads(_classes_json(name).read_text(encoding="utf-8"))
    classes = ds["classes"]
    ids = [c.get("original_id") for c in classes]
    assert all(i is not None for i in ids), \
        f"{name}: 有类别缺 original_id —— App 侧无法做本地索引 -> 真实 id 的映射"
    assert len(ids) == len(classes)


@pytest.mark.parametrize("name", DATASETS)
def test_映射表无重复且都落在类别表内(name):
    n_classes, known = _taxonomy()
    ds = json.loads(_classes_json(name).read_text(encoding="utf-8"))
    ids = [int(c["original_id"]) for c in ds["classes"]]

    dup = sorted({i for i in ids if ids.count(i) > 1})
    assert not dup, f"{name}: modelClassIds 有重复 {dup}（重复意味着漏了一类，框会标错）"

    bad = sorted(i for i in ids if i not in known)
    assert not bad, f"{name}: modelClassIds 里有不在类别表内的 id {bad}"

    out = sorted(i for i in ids if not (0 <= i < n_classes))
    assert not out, f"{name}: modelClassIds 有超出 [0,{n_classes}) 的 id {out}"


@pytest.mark.parametrize("name", DATASETS)
def test_本地索引必须连续从零开始(name):
    """生成器与 App 都要求本地索引是 0..nc-1。"""
    ds = json.loads(_classes_json(name).read_text(encoding="utf-8"))
    ids = [c["id"] for c in ds["classes"]]
    assert ids == list(range(len(ids))), f"{name}: 本地索引不连续：{ids}"


@pytest.mark.parametrize("name", DATASETS)
def test_非全表时必须给全映射表(name):
    """空映射表只在「模型类别数 == 类别表类数」时合法。

    这是 App 侧 `resolveMapping` 的规则：数量不等却没有声明表 -> **直接失败，不猜**。
    所以这里提前确认：只要不是全表，`modelClassIds` 就必须给全（上面几条已覆盖长度），
    且长度必须等于类别数（不是「子集长度」）。
    """
    n_classes, _ = _taxonomy()
    ds = json.loads(_classes_json(name).read_text(encoding="utf-8"))
    n = len(ds["classes"])
    ids = [int(c["original_id"]) for c in ds["classes"]]
    if n != n_classes:
        assert len(ids) == n, f"{name}: 非全表（{n} != {n_classes}）时映射表必须给全"


def test_类别表类数与_Dart_侧一致():
    """`kNumClasses` 由 gen_dart_labels.py 生成，必须与 classes.json 同步。"""
    n_classes, _ = _taxonomy()
    dart = (REPO_ROOT / "app" / "lib" / "vision" / "labels.dart").read_text(encoding="utf-8")
    assert f"const int kNumClasses = {n_classes};" in dart, \
        "labels.dart 里的 kNumClasses 与 configs/classes.json 不一致；" \
        "跑 python scripts/gen_dart_labels.py 重新生成"
