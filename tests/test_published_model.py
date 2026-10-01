"""守住「默认导出源 == 端上真正在跑的那一份模型」。

## 为什么需要这条测试

`export_tflite.py` 有一个默认权重路径。它曾经指向 `runs/pg_review_v0`——
那是一个 **24 类**模型，而类别表后来扩到 48 类、旧表已作废。
于是一条最普通的 `python scripts/export_tflite.py` 会导出一个类别数
与 `configs/classes.json` 对不上的模型，而且**不报错**，
只是每个框都被标成另一个类。

这类错在本项目出现过多次（索引错位、映射写死在 Dart 里），
共同点是「不崩、只是安静地错」。所以这里把它钉成不变量：

1. 默认权重必须存在；
2. 默认权重那次导出得到的 int8 tflite，必须**就是** `app/assets/models/` 里
   打进 APK 的那一份（逐字节相同）；
3. 随模型一起走的清单必须与模型自洽（字节数、sha256、类别映射）。

`runs/` 与 `data/` 是 gitignore 的构建产物，新克隆的仓库里没有，
所以第 2 条在缺文件时 **skip** 而不是 fail——skip 是诚实的，
假装通过才是问题。
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from export_tflite import ASSETS_MANIFEST, ASSETS_MODEL, DEFAULT_WEIGHTS  # noqa: E402

CLASSES_JSON = REPO_ROOT / "configs" / "classes.json"


def _sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def test_默认权重已指向某个_run():
    """默认权重必须是一个明确的 run，而不是「最近改过的那个」。"""
    assert DEFAULT_WEIGHTS.name == "best.pt"
    assert DEFAULT_WEIGHTS.parent.name == "weights"
    run_name = DEFAULT_WEIGHTS.parent.parent.name
    assert run_name.startswith("pg_"), f"默认 run 名字不像本项目产物：{run_name}"


def test_默认权重绝不能是已作废的_24_类_run():
    """pg_review_v0 是 24 类旧表的产物，类别表扩到 48 类后它就过时了。"""
    stale = REPO_ROOT / "runs" / "pg_review_v0" / "weights" / "best.pt"
    assert DEFAULT_WEIGHTS != stale, (
        "默认权重又指回了 24 类的 pg_review_v0；"
        "用默认参数导出会得到类别表对不上的模型，且不报错"
    )


def test_端上资产与清单都存在():
    """这两个文件是**提交进仓库**的（assets 不是构建产物），必须始终在。"""
    assert ASSETS_MODEL.exists(), f"缺少 {ASSETS_MODEL}；它应该随仓库提交"
    assert ASSETS_MANIFEST.exists(), f"缺少 {ASSETS_MANIFEST}；它由 export_tflite.py 生成"


def test_清单与端上模型自洽():
    m = json.loads(ASSETS_MANIFEST.read_text(encoding="utf-8"))
    data = ASSETS_MODEL.read_bytes()
    assert m["bytes"] == len(data), "清单字节数与模型文件不符——换过模型但没重生成清单"
    assert m["sha256"] == _sha256(ASSETS_MODEL), "清单 sha256 与模型文件不符"
    assert m["file"] == ASSETS_MODEL.name


def test_清单的类别映射落在类别表内():
    m = json.loads(ASSETS_MANIFEST.read_text(encoding="utf-8"))
    ids = m["modelClassIds"]
    assert len(ids) == m["modelClassCount"]
    assert len(set(ids)) == len(ids), "映射表有重复 id，意味着漏了一类"

    table = json.loads(CLASSES_JSON.read_text(encoding="utf-8"))
    known = {int(c["id"]) for c in table["classes"]}
    for i in ids:
        assert i in known, f"模型声明的 class id {i} 不在类别表里"


def test_默认导出源就是端上那一份():
    """DEFAULT_WEIGHTS 那次导出必须与打进 APK 的模型逐字节相同。

    这一条是「默认参数导出 → 复制到 assets」这条链路唯一能自动发现的漂移点：
    换了默认 run、或重训后忘了重导重拷，都会在这里断。
    """
    int8 = DEFAULT_WEIGHTS.parent / "best_saved_model" / "best_int8.tflite"
    if not int8.exists():
        pytest.skip(f"{int8} 不存在（runs/ 是 gitignore 的构建产物）")
    assert int8.read_bytes() == ASSETS_MODEL.read_bytes(), (
        f"默认导出源 {int8} 与端上 {ASSETS_MODEL} 不是同一份模型。\n"
        f"  默认源 sha256 {_sha256(int8)[:16]}…\n"
        f"  端上   sha256 {_sha256(ASSETS_MODEL)[:16]}…\n"
        "要么改 DEFAULT_WEIGHTS，要么重导并复制到 assets（并重生成清单）。"
    )
