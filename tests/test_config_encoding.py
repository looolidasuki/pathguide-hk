"""守住 `configs/` 下的 JSON 必须能被**普通 utf-8** 读取。

## 为什么值得专门写一条测试

Windows 上很多编辑器（记事本、VS Code 改设置后、PowerShell 的
`Set-Content -Encoding utf8`）保存 JSON 时会加 UTF-8 BOM。
Python 3 的**源码**容忍 BOM，所以 .py 文件没事；但 `json.load` 不容忍，
会抛 `Unexpected UTF-8 BOM (decode using utf-8-sig)`。

实测已经中过一次：`configs/commons_sources.json` 带上了 BOM，
于是 `scripts/fetch_commons_by_class.py` 直接跑不起来——
而报错信息里既不提 BOM 和哪个文件有关，也不提是"编码"问题，
只会在 `json.load` 抛一个 JSONDecodeError，看的人容易以为是文件内容坏了。

这条测试把「配置文件被另存过一次」变成一个**当场失败**，
而不是「过几天采集脚本跑不动」。
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG_FILES = sorted((REPO_ROOT / "configs").rglob("*.json"))

# 契约文件：这几份是别的脚本按普通 utf-8 读的，缺了就说明目录结构被改了
REQUIRED = ["classes.json", "commons_sources.json"]


def test_configs_目录下确实有_json():
    assert CONFIG_FILES, "configs/ 下没有 JSON——路径写错或目录被移走了"
    names = {p.name for p in CONFIG_FILES}
    for r in REQUIRED:
        assert r in names, f"缺少契约文件 configs/{r}"


@pytest.mark.parametrize("path", CONFIG_FILES, ids=lambda p: p.name)
def test_能被普通_utf8_读取且是合法_json(path: Path):
    raw = path.read_bytes()
    assert raw[:3] != b"\xef\xbb\xbf", (
        f"{path.relative_to(REPO_ROOT)} 带 UTF-8 BOM。\n"
        "  用普通 utf-8 读它的脚本会抛 Unexpected UTF-8 BOM。\n"
        f"  修法：把文件存成「UTF-8 无 BOM」，"
        f"或让读取方用 encoding='utf-8-sig'。"
    )
    try:
        json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError as e:
        pytest.fail(f"{path.relative_to(REPO_ROOT)} 不是合法 UTF-8：{e}")
    except json.JSONDecodeError as e:
        pytest.fail(f"{path.relative_to(REPO_ROOT)} 不是合法 JSON：{e}")


def test_采集配置的读取方容忍_BOM():
    """即使将来又有人存成带 BOM，采集脚本也必须还能读。

    文件本身去掉 BOM 是治本；读取方用 utf-8-sig 是兜底。
    两个都要有：治本防住「写坏了」，兜底防住「写坏了但没人发现」。
    """
    src = (REPO_ROOT / "scripts" / "fetch_commons_by_class.py").read_text(encoding="utf-8")
    assert "SOURCES_PATH.open(encoding=\"utf-8-sig\")" in src, (
        "fetch_commons_by_class.py 又用回普通 utf-8 读 configs/commons_sources.json 了；"
        "那样一旦配置文件被另存为带 BOM，采集脚本会直接失败"
    )
