"""第三方数据的标签**绝不能入库**。

## 为什么需要这条测试

`.gitignore` 里有一条 `!data/dataset/labels/**` —— 它存在的理由是
「我们自己的标注成果要入库」（标注很贵，重跑成本高）。
但它是**整个目录全放行**，所以任何落进 `data/dataset/labels/` 的东西都会被放行。

实测踩过：导入 Roboflow 的 7261 张图后 `git add -A`，
把 **7261 个别人的标注文件**一起提交了进去（commit 2014788，已修订）。

这有两个后果：
1. **许可**：不该把第三方的标注重新分发。CC BY-SA 要求署名，
   而其中还有未声明许可的上游；
2. **仓库**：7261 个文件、几 MB 的无意义体积。

所以这里把「该忽略什么、不该忽略什么」都钉住 ——
只钉前者的话，有人把 `!data/dataset/labels/**` 删掉就能"通过"测试。
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

# 第三方来源的目录名（与 docs/THIRD-PARTY-DATA.md 对应）
THIRD_PARTY_LABEL_DIRS = ["data/dataset/labels/roboflow_people_v1"]

# 我们自己的标注目录：必须仍然入库
OUR_LABEL_DIRS = ["data/dataset/labels/trashbin"]


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True, text=True)


def is_ignored(rel: str) -> bool:
    """用 `git check-ignore` 问 git 自己的判断，而不是复述 .gitignore 的文本。"""
    r = git("check-ignore", "-q", rel)
    return r.returncode == 0


@pytest.mark.parametrize("d", THIRD_PARTY_LABEL_DIRS)
def test_第三方标签被忽略(d):
    p = REPO_ROOT / d
    if not p.exists():
        pytest.skip(f"{d} 不存在（data/ 是 gitignore 的构建产物）")
    sample = next((f for f in p.glob("*.txt")), None)
    if sample is None:
        pytest.skip(f"{d} 下没有标签文件")
    rel = sample.relative_to(REPO_ROOT).as_posix()
    assert is_ignored(rel), (
        f"{rel} 会被提交！第三方数据集的标签绝不能入库"
        f"（许可问题）。检查 .gitignore 里那条 "
        f"`data/dataset/labels/roboflow_people_v1/**` 是否还在放行规则之后。"
    )


@pytest.mark.parametrize("d", OUR_LABEL_DIRS)
def test_我们自己的标签仍然入库(d):
    """反向守卫：别为了挡第三方而把我们自己的标注一起挡掉。

    标注是人工成果、重跑成本高，丢了就得重新标。
    """
    p = REPO_ROOT / d
    if not p.exists():
        pytest.skip(f"{d} 不存在")
    sample = next((f for f in p.glob("*.txt")), None)
    if sample is None:
        pytest.skip(f"{d} 下没有标签文件")
    rel = sample.relative_to(REPO_ROOT).as_posix()
    assert not is_ignored(rel), (
        f"{rel} 被忽略了——我们自己的标注是**要入库**的（人工成果，重跑成本高）。"
        f"检查 .gitignore 是否把 data/dataset/labels/ 整体挡掉了。"
    )


def test_索引里没有任何第三方标签():
    """最终防线：直接问 git 索引里有没有。"""
    r = git("ls-files")
    if r.returncode != 0:
        pytest.skip(f"git ls-files 失败：{r.stderr[:200]}")
    tracked = r.stdout.splitlines()
    bad = [f for f in tracked
           if any(f.startswith(d + "/") for d in THIRD_PARTY_LABEL_DIRS)]
    assert not bad, (
        f"索引里有 {len(bad)} 个第三方标签文件，例如 {bad[:3]}。\n"
        f"修法：git rm -r --cached {' '.join(THIRD_PARTY_LABEL_DIRS)}"
    )


def test_第三方图像也不在索引里():
    r = git("ls-files")
    if r.returncode != 0:
        pytest.skip("git ls-files 失败")
    tracked = r.stdout.splitlines()
    bad = [f for f in tracked if "roboflow_people_v1" in f and f.endswith((".jpg", ".png"))]
    assert not bad, f"索引里有第三方**图像**：{bad[:3]}"
