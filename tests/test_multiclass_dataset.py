"""`build_multiclass_dataset.py` 的本地索引分配与 train-only 切分。

这两条都在守「静默错标签」：

1. **同一个类来自多个目录必须合成一类。**
   旧写法按 `--add` 条目顺序分配本地索引，于是
   `--add A:pedestrian --add B:pedestrian` 会得到索引 0 和 1 —— **两个行人类**。
   它不报错：模型多输出一路，两路各拿到一半标签，指标看着还挺正常，
   而 App 侧的 `modelClassIds` 会因此少一项、整体错位。

2. **第三方聚合数据必须能只进 train。**
   Roboflow 那类数据自带逐图随机划分，同一段视频的相邻帧会跨 train/val。
   混进 val 会让 val 既不代表性、又有泄漏 —— 所有验证数字失去意义，
   而数字照样会打印出来。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import build_multiclass_dataset as B  # noqa: E402


def make_single_class_dir(root: Path, sub: str, frames: dict[str, int]) -> Path:
    """造一个单类数据集目录：labels 使用本地索引 0，`frames` 是 帧名 -> 框数。"""
    d = root / sub
    (d / "images" / "src").mkdir(parents=True)
    (d / "labels" / "src").mkdir(parents=True)
    for name, nbox in frames.items():
        (d / "images" / "src" / f"{name}.jpg").write_bytes(b"\xff\xd8\xff\xe0fakejpg")
        lines = [f"0 0.5 0.5 0.2 0.2" for _ in range(nbox)]
        (d / "labels" / "src" / f"{name}.txt").write_text("\n".join(lines) + "\n",
                                                         encoding="utf-8")
    return d


def run(monkeypatch, argv: list[str]) -> int:
    monkeypatch.setattr(sys, "argv", ["build_multiclass_dataset.py", *argv])
    return B.main()


def read_classes(out: Path) -> list[dict]:
    return json.loads((out / "classes.json").read_text(encoding="utf-8"))["classes"]


def test_同一个类来自两个目录只分配一个本地索引(monkeypatch, tmp_path):
    a = make_single_class_dir(tmp_path, "ped_a", {f"a{i}": 1 for i in range(6)})
    b = make_single_class_dir(tmp_path, "ped_b", {f"b{i}": 1 for i in range(6)})
    out = tmp_path / "out"
    rc = run(monkeypatch, ["--out", str(out),
                           "--add", f"{a}:pedestrian", "--add", f"{b}:pedestrian"])
    assert rc == 0
    classes = read_classes(out)
    assert len(classes) == 1, f"应只为一个类，实际 {[c['name_en'] for c in classes]}"
    assert classes[0]["name_en"] == "pedestrian"
    assert classes[0]["id"] == 0
    assert classes[0]["original_id"] == 6

    # 两个目录的帧都要在，且标签里只出现索引 0
    labels = sorted((out / "labels").rglob("*.txt"))
    assert len(labels) == 12
    for p in labels:
        for ln in p.read_text(encoding="utf-8").splitlines():
            assert ln.split()[0] == "0"


def test_不同类各自拿到自己的索引(monkeypatch, tmp_path):
    ped = make_single_class_dir(tmp_path, "ped", {f"p{i}": 1 for i in range(4)})
    bike = make_single_class_dir(tmp_path, "bike", {f"b{i}": 1 for i in range(4)})
    out = tmp_path / "out"
    rc = run(monkeypatch, ["--out", str(out),
                           "--add", f"{ped}:pedestrian", "--add", f"{bike}:bicycle"])
    assert rc == 0
    by_name = {c["name_en"]: c for c in read_classes(out)}
    assert by_name["pedestrian"]["id"] == 0
    assert by_name["bicycle"]["id"] == 1
    assert by_name["pedestrian"]["original_id"] == 6
    assert by_name["bicycle"]["original_id"] == 11


def test_train_only_来源一张都不进_val(monkeypatch, tmp_path):
    hk = make_single_class_dir(tmp_path, "hk_ped", {f"hk{i}": 1 for i in range(50)})
    rf = make_single_class_dir(tmp_path, "rf_ped", {f"rf{i}": 1 for i in range(50)})
    out = tmp_path / "out"
    rc = run(monkeypatch, ["--out", str(out),
                           "--add", f"{hk}:pedestrian",
                           "--add-train-only", f"{rf}:pedestrian"])
    assert rc == 0

    train = {p.stem for p in (out / "labels" / "train").glob("*.txt")}
    val = {p.stem for p in (out / "labels" / "val").glob("*.txt")}
    assert val, "val 不能为空"
    assert len(train | val) == 100, "两个来源的 100 张都应在"
    # 50 张 hk 按 20% 切 -> val 10 张；50 张 rf 全部进 train -> train 90 张
    assert len(val) == 10, f"val 应只有 hk 的 20%，实际 {len(val)}"
    assert len(train) == 90, f"train 应为 40(hk) + 50(rf)，实际 {len(train)}"


def test_train_only_的帧名全部出现在_train(monkeypatch, tmp_path):
    hk = make_single_class_dir(tmp_path, "hk", {f"h{i}": 1 for i in range(20)})
    rf = make_single_class_dir(tmp_path, "rf", {f"r{i}": 1 for i in range(20)})
    out = tmp_path / "out"
    rc = run(monkeypatch, ["--out", str(out),
                           "--add", f"{hk}:pedestrian",
                           "--add-train-only", f"{rf}:pedestrian"])
    assert rc == 0
    # 用 manifest.csv 的 source_image 路径判断来源，比猜文件名可靠
    import csv
    rows = list(csv.DictReader((out / "manifest.csv").open(encoding="utf-8")))
    rf_in_val = [r for r in rows
                 if r["split"] == "val" and f"{Path('rf')}" in r["source_image"]]
    rf_in_train = [r for r in rows
                   if r["split"] == "train" and f"{Path('rf')}" in r["source_image"]]
    assert not rf_in_val, f"train-only 来源有 {len(rf_in_val)} 张进了 val"
    assert len(rf_in_train) == 20, f"train-only 来源应有 20 张进 train，实际 {len(rf_in_train)}"


def test_必须至少给一个来源(monkeypatch, tmp_path):
    rc = run(monkeypatch, ["--out", str(tmp_path / "out")])
    assert rc == 1


def test_类名不在类别表里要失败(monkeypatch, tmp_path):
    d = make_single_class_dir(tmp_path, "x", {"a": 1})
    rc = run(monkeypatch, ["--out", str(tmp_path / "out"), "--add", f"{d}:not_a_class"])
    assert rc == 1


def test_源目录不存在要失败(monkeypatch, tmp_path):
    rc = run(monkeypatch, ["--out", str(tmp_path / "out"),
                           "--add", f"{tmp_path/'无此目录'}:pedestrian"])
    assert rc == 1


# ---------- 多类来源（--add-multi-train-only）----------

def make_multiclass_dir(root: Path, sub: str, frames: dict[str, list[int]]) -> Path:
    """造一个多类数据集目录：标签用**项目 id**（configs/classes.json 的 id）。"""
    d = root / sub
    (d / "images" / "src").mkdir(parents=True)
    (d / "labels" / "src").mkdir(parents=True)
    for name, ids in frames.items():
        (d / "images" / "src" / f"{name}.jpg").write_bytes(b"\xff\xd8\xff\xe0fakejpg")
        lines = [f"{i} 0.5 0.5 0.2 0.2" for i in ids]
        (d / "labels" / "src" / f"{name}.txt").write_text("\n".join(lines) + "\n",
                                                         encoding="utf-8")
    return d


def test_多类来源按项目id映射到本地索引(monkeypatch, tmp_path):
    """多类来源的标签写的是**项目 id**（6=pedestrian, 11=bicycle, 7=bin），
    必须按类名分配本地索引，而不是把 6/11/7 原样当成本地索引。

    搞错的话模型输出维度与标签对不上——不报错，只是每类都学错。
    """
    hk = make_single_class_dir(tmp_path, "hk_ped", {f"h{i}": 1 for i in range(10)})
    multi = make_multiclass_dir(tmp_path, "multi", {
        "m0": [6], "m1": [11], "m2": [6, 11], "m3": [7],
    })
    out = tmp_path / "out"
    rc = run(monkeypatch, ["--out", str(out),
                           "--add", f"{hk}:pedestrian",
                           "--add-multi-train-only", str(multi)])
    assert rc == 0
    by_name = {c["name_en"]: c["id"] for c in read_classes(out)}
    # 本地索引按类名首次出现顺序：pedestrian(hk 先) = 0，bicycle = 1，bin = 2
    assert by_name["pedestrian"] == 0
    assert by_name["bicycle"] == 1
    assert by_name["bin"] == 2

    # 标签里必须只有 0/1/2，不能出现 6/7/11
    seen = set()
    for p in (out / "labels").rglob("*.txt"):
        for ln in p.read_text(encoding="utf-8").splitlines():
            if ln.strip():
                seen.add(int(ln.split()[0]))
    assert seen <= {0, 1, 2}, f"出现了非本地索引：{seen}"


def test_多类来源的帧全部进_train(monkeypatch, tmp_path):
    hk = make_single_class_dir(tmp_path, "hk", {f"h{i}": 1 for i in range(20)})
    multi = make_multiclass_dir(tmp_path, "multi", {f"m{i}": [6] for i in range(20)})
    out = tmp_path / "out"
    rc = run(monkeypatch, ["--out", str(out),
                           "--add", f"{hk}:pedestrian",
                           "--add-multi-train-only", str(multi)])
    assert rc == 0
    import csv as _csv
    rows = list(_csv.DictReader((out / "manifest.csv").open(encoding="utf-8")))
    multi_val = [r for r in rows if r["split"] == "val" and "multi" in r["source_image"]]
    multi_train = [r for r in rows if r["split"] == "train" and "multi" in r["source_image"]]
    assert not multi_val, f"多类来源有 {len(multi_val)} 张进了 val"
    assert len(multi_train) == 20


def test_多类来源里不在类别表的_id_被跳过且报出(monkeypatch, tmp_path, capsys):
    """表外 id 必须**报出**而不是静默丢——静默丢会让某些类的框凭空消失。"""
    multi = make_multiclass_dir(tmp_path, "multi", {"m0": [6, 999]})
    out = tmp_path / "out"
    rc = run(monkeypatch, ["--out", str(out),
                           "--add-multi-train-only", str(multi)])
    assert rc == 0
    captured = capsys.readouterr().out
    assert "999" in captured, "表外 id 必须打印出来"
    # 只有 6 那一框被保留
    lbl = next((out / "labels").rglob("*.txt"))
    assert len([l for l in lbl.read_text(encoding="utf-8").splitlines() if l.strip()]) == 1


def test_没有给任何来源要失败(monkeypatch, tmp_path):
    rc = run(monkeypatch, ["--out", str(tmp_path / "out")])
    assert rc == 1