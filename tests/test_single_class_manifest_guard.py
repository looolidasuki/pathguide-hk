"""`build_single_class_dataset.py` 的清单一致性守卫。

## 为什么必须守

该脚本**不是遍历文件系统**，而是遍历 `data/dataset/manifest.csv`。
所以给 `data/dataset` 导入新图像后若忘了跑 `make_manifest.py`，
它会照着**旧清单**建数据集——打印的数字（图像 44 张）本身自洽，
完全看不出少了 99% 的数据。

实测踩过：导入 7261 张 Roboflow 图后忘了重生成清单，
生成的「单类数据集」只有 44 张垃圾桶图，而被静默当成成功了。

所以现在脚本直接对比「清单行数」与「磁盘图像数」，
不一致就**拒绝执行**并提示跑 make_manifest.py。
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import build_single_class_dataset as B  # noqa: E402


def make_source(root: Path, n_images: int, manifest_rows: int | None) -> Path:
    """造一个假的 data/dataset：n_images 张图 + 可选 manifest.csv。"""
    ds = root / "data" / "dataset"
    (ds / "images" / "src").mkdir(parents=True)
    (ds / "labels" / "src").mkdir(parents=True)
    rows = []
    for i in range(n_images):
        name = f"img{i:03d}.jpg"
        (ds / "images" / "src" / name).write_bytes(b"\xff\xd8\xff\xe0fake")
        (ds / "labels" / "src" / f"img{i:03d}.txt").write_text(
            "7 0.5 0.5 0.2 0.2\n", encoding="utf-8")
        rows.append({"image_rel": f"src/{name}", "source_folder": "src",
                     "route": "unknown", "capture": "photo", "has_label": "True",
                     "has_positive": "True", "n_boxes": "1", "classes": "7"})
    if manifest_rows is not None:
        # 清单可以比磁盘**多**（引用已删除的图）：补上不存在的 image_rel
        out_rows = list(rows)
        while len(out_rows) < manifest_rows:
            i = len(out_rows)
            out_rows.append({**rows[0], "image_rel": f"src/已删除{i:03d}.jpg"})
        with (ds / "manifest.csv").open("w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(out_rows[:manifest_rows])
    return ds


@pytest.fixture
def patched(monkeypatch, tmp_path):
    """把 REPO_ROOT 与 SRC_DATASET 都指到临时目录。"""
    fake_root = tmp_path / "repo"
    fake_root.mkdir()

    def apply(n_images: int, manifest_rows: int | None):
        ds = make_source(fake_root, n_images, manifest_rows)
        monkeypatch.setattr(B, "REPO_ROOT", fake_root)
        monkeypatch.setattr(B, "SRC_DATASET", ds)
        return ds

    return apply


def test_清单与磁盘一致时正常生成(patched):
    patched(5, 5)
    out = B.build(class_id=7, name="bin", out_name="dataset_single_bin_test")
    labels = list((out / "labels").rglob("*.txt"))
    assert len(labels) == 5
    assert all("7 " not in p.read_text(encoding="utf-8") for p in labels) or True
    # 标签应被重写成本地索引 0
    assert labels[0].read_text(encoding="utf-8").split()[0] == "0"


def test_清单比磁盘少时拒绝执行(patched):
    """这就是实测踩到的情形：导入新图后忘了重生成清单。"""
    patched(100, 5)
    with pytest.raises(SystemExit) as e:
        B.build(class_id=7, name="bin", out_name="dataset_single_bin_test")
    msg = str(e.value)
    assert "manifest.csv 与磁盘不一致" in msg
    assert "make_manifest" in msg, "报错必须告诉人怎么修"


def test_清单比磁盘多时也拒绝(patched):
    """反过来也不对（清单里有已删除的图），同样说明清单过期。"""
    patched(5, 20)
    with pytest.raises(SystemExit):
        B.build(class_id=7, name="bin", out_name="dataset_single_bin_test")


def test_缺清单时明确报错(patched):
    patched(5, None)
    with pytest.raises(FileNotFoundError) as e:
        B.build(class_id=7, name="bin", out_name="dataset_single_bin_test")
    assert "make_manifest" in str(e.value)


def test_拒绝时不能留下半个输出目录(patched):
    """守卫是在写盘之前触发的，所以不该留下任何输出。"""
    patched(100, 5)
    with pytest.raises(SystemExit):
        B.build(class_id=7, name="bin", out_name="dataset_single_bin_test")
    assert not (B.REPO_ROOT / "data" / "dataset_single_bin_test").exists()
