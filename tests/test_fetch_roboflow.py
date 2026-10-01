"""`fetch_roboflow.py` 里不依赖网络的纯逻辑。

下载本身要有效 key 才能测；但**类别映射建议**和**key 读取**是纯函数，
而且这两处出错的方式都很隐蔽：
- key 读取：读错地方 -> 报「没找到 key」，而人会以为是 key 本身的问题；
- 映射建议：把 `person` 悄悄映到别的类 -> 标签整体错位，且不报错。

所以这两处用**临时文件**测，不读真实的 `.env.secret.ps1`——
那份文件是 gitignore 的，别人克隆的仓库里没有，
测试若依赖它就会在别人机器上失败（而失败原因与代码无关，最浪费时间）。
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import fetch_roboflow  # noqa: E402
from fetch_roboflow import load_target_classes, read_key, suggest_override  # noqa: E402


# ---------- key 读取 ----------

def test_从环境变量读_key(monkeypatch):
    monkeypatch.setenv("ROBOFLOW_API_KEY", "envkey123456")
    monkeypatch.setattr(fetch_roboflow, "SECRET_PATH", Path("不存在的文件.ps1"))
    assert read_key() == "envkey123456"


def test_从_ps1_文件读_key_并去掉引号(monkeypatch, tmp_path):
    f = tmp_path / ".env.secret.ps1"
    f.write_text(
        "# 注释里有 ROBOFLOW_API_KEY 字样，不能被当成值\n"
        '$env:ROBOFLOW_API_KEY  = "abc123xyz789"\n',
        encoding="utf-8",
    )
    monkeypatch.delenv("ROBOFLOW_API_KEY", raising=False)
    monkeypatch.setattr(fetch_roboflow, "SECRET_PATH", f)
    assert read_key() == "abc123xyz789"


def test_注释行不被当成_key(monkeypatch, tmp_path):
    """真实文件里第一行就是含 `ROBOFLOW_API_KEY` 的中文注释。

    若不跳过注释行，就会把注释内容读成 key，然后报「401 无效」——
    而人会觉得"key 明明是刚生成的"。这个坑值得钉住。
    """
    f = tmp_path / ".env.secret.ps1"
    f.write_text(
        "# 获取方式：Roboflow Dashboard -> Account -> Roboflow Keys\n"
        "$env:ROBOFLOW_API_KEY = 'realvalue'\n",
        encoding="utf-8",
    )
    monkeypatch.delenv("ROBOFLOW_API_KEY", raising=False)
    monkeypatch.setattr(fetch_roboflow, "SECRET_PATH", f)
    assert read_key() == "realvalue"


def test_空值返回_None_而不是抛异常(monkeypatch, tmp_path):
    f = tmp_path / ".env.secret.ps1"
    f.write_text('$env:ROBOFLOW_API_KEY = ""\n', encoding="utf-8")
    monkeypatch.delenv("ROBOFLOW_API_KEY", raising=False)
    monkeypatch.setattr(fetch_roboflow, "SECRET_PATH", f)
    assert read_key() is None


def test_文件不存在时返回_None_而不是抛异常(monkeypatch, tmp_path):
    monkeypatch.delenv("ROBOFLOW_API_KEY", raising=False)
    monkeypatch.setattr(fetch_roboflow, "SECRET_PATH", tmp_path / "无此文件")
    assert read_key() is None


# ---------- 类别映射建议 ----------

def test_项目类别表里的三个_id_与端上模型映射一致():
    """端上模型的映射是 [6, 11, 7] = pedestrian / bicycle / bin。

    这三个 id 是跨语言契约：Roboflow 导入用它、Dart 标签用它、
    模型清单的 modelClassIds 也用它。对不上就是静默错类。
    """
    by_en = {c["name_en"]: c["id"] for c in load_target_classes()}
    assert by_en["pedestrian"] == 6
    assert by_en["bicycle"] == 11
    assert by_en["bin"] == 7


def test_person_与_people_都映到_pedestrian():
    targets = load_target_classes()
    ov = suggest_override(["person", "people", "pedestrian"], targets)
    assert ov["person"] == 6 and ov["people"] == 6 and ov["pedestrian"] == 6


def test_别名与大小写不敏感():
    targets = load_target_classes()
    ov = suggest_override(["Person", "BIKE", "Trash Bin"], targets)
    assert ov["Person"] == 6
    assert ov["BIKE"] == 11
    assert ov["Trash Bin"] == 7


def test_认不出的类别不猜():
    """无法映射的类别必须**缺席**，而不是被猜成某个类。

    猜错的代价是每帧标签都错；缺席的代价只是这个类的框被跳过（会打印警告）。
    """
    targets = load_target_classes()
    ov = suggest_override(["person", "traffic light", "dog"], targets)
    assert ov["person"] == 6
    assert "traffic light" not in ov
    assert "dog" not in ov


def test_映射结果必须都是类别表里真实存在的_id():
    targets = load_target_classes()
    known = {c["id"] for c in targets}
    ov = suggest_override(
        ["person", "people", "bike", "bicycle", "trash", "bin", "litter bin"], targets)
    assert ov
    for name, cid in ov.items():
        assert cid in known, f"{name} 被映到了不存在的 id {cid}"


def test_空类别列表不会崩():
    assert suggest_override([], load_target_classes()) == {}


@pytest.mark.parametrize("name", ["garbage bin", "trash bin", "litter bin", "bin"])
def test_垃圾桶的各种写法都映到_7(name):
    assert suggest_override([name], load_target_classes())[name] == 7


@pytest.mark.parametrize("name", ["persons", "Pessoa", "Persona", "human"])
def test_人的各语言写法都映到_6(name):
    """实测 chris-law/people-detection 声明了 63 个类，其中「人」有 8 种写法。

    漏掉其中任何一种，都会让那部分框被**静默跳过**——
    而跳过的人框不会报错，只会让训练集里少一批人。
    """
    assert suggest_override([name], load_target_classes())[name] == 6


@pytest.mark.parametrize("name", [
    "Cyclist",     # 骑车的人 ≠ 单車（障碍物）
    "cyclist",
    "player",      # 歧义：人？还是球员？
    "head", "face", "helmet",   # 身体部位/穿戴物
    "Signboard",   # 招牌 ≠ 指示牌
    "Stopper",     # 语义不明
    "diningtable", "chair",     # 与本项目 table(桌椅) 不等价
    "0", "1", "6",              # 无名数字类
    "high", "medium", "low",    # 疑似密度/置信度分档
    "dianzhuan", "jatuh", "berdiri",
    "car", "Car", "auto", "truck", "bus", "motorbike",   # 本项目无车辆类
])
def test_这些类别必须保持不映射(name):
    """这条守的是「好心加别名」这类改动。

    把 `Cyclist` 映成 `bicycle` 看起来很方便，但骑车的人是「人+车」，
    映过去会让视障用户听到「單車」而实际前方是一个骑过来的人——
    误报的代价不对称。同理车辆类：本项目的类别表里根本没有车辆。
    宁可让这些框被跳过并打印警告，也不要猜。
    """
    assert name not in suggest_override([name], load_target_classes()), (
        f"{name} 被映射了。若确实要映射，请先确认语义等价并在 "
        f"suggest_override 的说明表里删掉对应的「不映射」理由。"
    )
