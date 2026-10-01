"""Roboflow `data.yaml` 的类别名解析。

## 为什么专门写这一组

`read_yaml_names` 曾经对**真实**的 Roboflow 导出返回空列表：
它假定 `names:` 下的列表项是缩进的，而 Roboflow 导出的是**顶格**写法
（`- '0'` 在第 0 列），于是第一项就 break。

后果不是报错，而是安静地错到底：
空类别表 -> 映射为空 -> 每个框都被跳过 -> 仍然写出**空标签文件**，
而空标签是有效负样本，等于往训练集里灌几千张「什么都没有」的错误样本。

所以这里的第一条测试直接钉**真实文件的确切写法**。
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from import_roboflow import map_class, read_yaml_names  # noqa: E402

# 与 Roboflow 导出**逐字符同构**的最小样例（列表项顶格）
ROBOFLOW_STYLE = """names:
- '0'
- Bicycle
- Pedestrian
- Persona
- bicycle
- person
nc: 6
roboflow:
  license: Private
  project: people-detection-o4rdr-nlryq
  version: 1
test: ../test/images
train: ../train/images
val: ../valid/images
"""


def _write(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "data.yaml"
    p.write_text(text, encoding="utf-8")
    return p


def test_顶格块序列必须能读出来(tmp_path):
    """这条就是那个 bug 的回归测试：返回空列表就意味着几千张错误负样本。"""
    names = read_yaml_names(_write(tmp_path, ROBOFLOW_STYLE))
    assert names == ["0", "Bicycle", "Pedestrian", "Persona", "bicycle", "person"]


def test_必须停在_names_块结束处(tmp_path):
    """不能把 nc: / roboflow: / train: 当成类别名。"""
    names = read_yaml_names(_write(tmp_path, ROBOFLOW_STYLE))
    for bad in ("nc", "roboflow", "license", "project", "version", "train", "val", "test"):
        assert bad not in names, f"{bad} 被误当成类别名"


def test_缩进块序列也能读(tmp_path):
    names = read_yaml_names(_write(tmp_path, "names:\n  - cat\n  - dog\nnc: 2\n"))
    assert names == ["cat", "dog"]


def test_缩进映射写法能读(tmp_path):
    names = read_yaml_names(_write(tmp_path, "names:\n  0: cat\n  1: dog\nnc: 2\n"))
    assert names == ["cat", "dog"]


def test_单行写法能读(tmp_path):
    names = read_yaml_names(_write(tmp_path, "names: ['cat', 'dog']\nnc: 2\n"))
    assert names == ["cat", "dog"]


def test_去掉引号(tmp_path):
    names = read_yaml_names(_write(tmp_path, "names:\n- '0'\n- \"a b\"\n"))
    assert names == ["0", "a b"]


def test_文件不存在返回空列表而不是抛异常(tmp_path):
    assert read_yaml_names(tmp_path / "无此文件.yaml") == []


def test_names_前面有别的键也能正确找到(tmp_path):
    text = "path: /tmp/x\ntrain: images/train\nnames:\n- cat\nnc: 1\n"
    assert read_yaml_names(_write(tmp_path, text)) == ["cat"]


def test_空类别名被过滤(tmp_path):
    names = read_yaml_names(_write(tmp_path, "names:\n- cat\n- ''\n- dog\n"))
    assert names == ["cat", "dog"]


# ---------- 与映射函数连起来 ----------

def test_顶格写法读出的类别_不带_override_时只有精确匹配能映上(tmp_path):
    """这条钉住一个**真实的陷阱**。

    `import_roboflow.py::map_class` 只做精确名与紧凑名匹配，
    它**不认识** `person -> pedestrian` 这类别名（别名表在 fetch_roboflow.py）。
    所以忘了传 `--class-override` 时，只有名字恰好等于本项目类名的才能映上：

        Pedestrian -> pedestrian   ✅ 精确匹配
        bicycle / Bicycle         ✅
        person / Persona / Pessoa / people / persons / bike / Bike   ❌ 全丢

    而这些丢掉的正是**数据的大头**。丢的方式是「打印未映射警告后跳过」——
    会打印是好事，但如果人不看输出，就会以为导入成功了。
    所以 fetch_roboflow.py 必须把 override 一起给出，且不能让人漏掉。
    """
    names = read_yaml_names(_write(tmp_path, ROBOFLOW_STYLE))
    targets = [
        {"id": 6, "name_en": "pedestrian"},
        {"id": 7, "name_en": "bin"},
        {"id": 11, "name_en": "bicycle"},
    ]
    mapping, unmatched = map_class(names, targets)
    # Bicycle(1) ✅ bicycle(4) ✅ Pedestrian(2) ✅（大小写不敏感后与 pedestrian 精确相等）
    # 而 person / Persona 丢——它们才是「人」的大头
    assert mapping == {1: 11, 2: 6, 4: 11}
    assert set(unmatched) == {"0", "Persona", "person"}


def test_带上_override_后全部别名都能映上(tmp_path):
    """带上 fetch_roboflow.py 给出的 override 后，不该有任何变体被漏掉。"""
    names = read_yaml_names(_write(tmp_path, ROBOFLOW_STYLE))
    targets = [
        {"id": 6, "name_en": "pedestrian"},
        {"id": 7, "name_en": "bin"},
        {"id": 11, "name_en": "bicycle"},
    ]
    override = {"Bicycle": 11, "Pedestrian": 6, "Persona": 6,
                "bicycle": 11, "person": 6}
    mapping, unmatched = map_class(names, targets, override)
    assert mapping == {1: 11, 2: 6, 3: 6, 4: 11, 5: 6}, mapping
    # 只有无名数字类 '0' 该剩下
    assert unmatched == ["0"]


def test_真实下载的_data_yaml_如果有就必须能读出类别():
    """只在真下过数据集时才跑——data/ 是 gitignore 的，别人克隆的仓库里没有。"""
    yaml_path = REPO_ROOT / "data" / "raw" / "roboflow" / "data.yaml"
    if not yaml_path.exists():
        pytest.skip("data/raw/roboflow 不存在（data/ 是 gitignore 的）")
    names = read_yaml_names(yaml_path)
    assert names, f"{yaml_path} 读出的类别为空——这正是那个 bug 的症状"
    assert len(names) > 40, f"只读出 {len(names)} 个类别，可疑"
