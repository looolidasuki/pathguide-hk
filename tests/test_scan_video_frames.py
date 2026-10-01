"""视频扫描流水线（scan_video_frames）。

这条流水线最初的写法是「有检出就留帧」，**实测证明那等于没筛**
（12 张真实街景在不同门槛下保留率都是 100%，见 probe_scan_selectivity.py）。
现在改成按类别定额取前 K，它才是真正的筛选手段，所以这里重点测选帧逻辑：
选错了要么漏掉好帧、要么把同一堵墙选十遍，两种都只能在人工复核时才发现。
"""
import csv
from pathlib import Path

import pytest

import scan_video_frames as S


def _d(cid: int, conf: float) -> dict:
    return {"class_id": cid, "conf": conf, "bbox": (0.1, 0.1, 0.2, 0.2)}


# ---------------------------------------------------------------- 每帧分数归约

def test_frame_scores_keep_only_the_per_class_max():
    """同一类在一帧里出多个框时只记最高分——选帧只问「这帧对这类有多像」。"""
    dets = [_d(7, 0.4), _d(7, 0.9), _d(7, 0.6), _d(11, 0.3)]
    assert S.frame_class_scores(dets, min_score=0.0) == {7: 0.9, 11: 0.3}


def test_frame_scores_drop_weak_detections():
    """零样本噪声很大，必须有下限，否则任何一帧都能凑出候选。"""
    dets = [_d(7, 0.24), _d(11, 0.25)]
    assert S.frame_class_scores(dets, min_score=0.25) == {11: 0.25}


def test_frame_scores_empty_frame():
    assert S.frame_class_scores([], min_score=0.25) == {}


# ---------------------------------------------------------------- 按类定额

def test_select_takes_top_k_per_class():
    frames = {
        ("v", 0): {7: 0.30},
        ("v", 1): {7: 0.90},
        ("v", 2): {7: 0.60},
    }
    sel = S.select_by_class(frames, per_class=2)
    # 保留分最高的两帧（1 与 2），最低的 0 被淘汰
    assert set(sel) == {("v", 1), ("v", 2)}
    assert all(c == {7} for c in sel.values())


def test_select_is_deterministic_on_ties():
    """同分时结果必须稳定。

    否则同一份素材两次扫描可能选出不同的帧，复核清单会对不上号。
    """
    frames = {("v", 5): {7: 0.5}, ("v", 3): {7: 0.5}, ("v", 4): {7: 0.5}}
    sel = S.select_by_class(frames, per_class=2)
    assert set(sel) == {("v", 3), ("v", 4)}


def test_select_marks_a_frame_for_every_class_that_chose_it():
    """一帧可同时被多个类选中，只存一张图。"""
    frames = {("v", 0): {7: 0.9, 11: 0.8}}
    sel = S.select_by_class(frames, per_class=1)
    assert sel[("v", 0)] == {7, 11}


def test_select_quota_is_per_class_not_global():
    """配额是「每类 K 帧」，不是「总共 K 帧」。

    写错会让先遍历到的类吃光全部配额，后面的类一帧都选不上——
    而表面上只是「选出来的帧数不对」。
    """
    frames = {
        ("v", 0): {7: 0.9}, ("v", 1): {7: 0.8}, ("v", 2): {7: 0.7},
        ("v", 3): {11: 0.6}, ("v", 4): {11: 0.5},
    }
    sel = S.select_by_class(frames, per_class=2)
    chosen = {cid for c in sel.values() for cid in c}
    assert chosen == {7, 11}
    assert sum(1 for c in sel.values() if 7 in c) == 2
    assert sum(1 for c in sel.values() if 11 in c) == 2


def test_select_reports_nothing_for_a_class_with_no_candidate():
    """某类一帧都没选上时必须不出现在结果里（报告据此列「没找到」）。"""
    frames = {("v", 0): {7: 0.9}}
    sel = S.select_by_class(frames, per_class=5)
    assert {cid for c in sel.values() for cid in c} == {7}


def test_select_keeps_frames_from_different_videos_separately():
    frames = {("a.mp4", 0): {7: 0.9}, ("b.mp4", 0): {7: 0.8}}
    sel = S.select_by_class(frames, per_class=1)
    assert set(sel) == {("a.mp4", 0)}          # 每类 1 帧，跨视频一起排序
    sel2 = S.select_by_class(frames, per_class=2)
    assert set(sel2) == {("a.mp4", 0), ("b.mp4", 0)}


# ---------------------------------------------------------------- 依据文本

def test_score_text_is_sorted_and_truncated():
    names = {7: "bin", 11: "bicycle", 25: "crowds"}
    text, top, n = S.class_score_text({11: 0.31, 7: 0.62, 25: 0.90}, names)
    assert text == "crowds:0.90;bin:0.62;bicycle:0.31"
    assert top == 0.90
    assert n == 3


def test_score_text_truncates_but_counts_all():
    """摘要可以截断，但类别数要如实报告，否则看不出「这帧其实很杂」。"""
    names = {i: f"c{i}" for i in range(10)}
    scores = {i: 0.1 * (i + 1) for i in range(10)}
    text, top, n = S.class_score_text(scores, names, max_classes=3)
    assert text == "c9:1.00;c8:0.90;c7:0.80"
    assert n == 10
    assert top == 1.0


def test_score_text_unknown_class_falls_back_to_id():
    assert S.class_score_text({999: 0.5}, {})[0] == "999:0.50"


def test_score_text_empty_is_safe():
    text, top, n = S.class_score_text({}, {7: "bin"})
    assert (text, top, n) == ("", 0.0, 0)


# ---------------------------------------------------------------- 视频发现

def test_resolve_videos_accepts_a_direct_file(tmp_path):
    vid = tmp_path / "a.mp4"
    vid.write_bytes(b"x")
    args = type("A", (), {"videos": [str(vid)]})()
    assert S.resolve_videos(args) == [vid]


def test_resolve_videos_ignores_non_video_paths(tmp_path, capsys):
    other = tmp_path / "notes.txt"
    other.write_text("hi", encoding="utf-8")
    args = type("A", (), {"videos": [str(other)]})()
    assert S.resolve_videos(args) == []
    assert "跳过" in capsys.readouterr().out


def test_resolve_videos_dedups_the_same_file_given_twice(tmp_path):
    vid = tmp_path / "a.mp4"
    vid.write_bytes(b"x")
    args = type("A", (), {"videos": [str(vid), str(tmp_path)]})()
    assert S.resolve_videos(args) == [vid]


# ---------------------------------------------------------------- 去重

def _textured(path: Path, seed: int) -> None:
    """写一张有纹理的测试图。

    纯色图会让 phash 退化：实测任何非黑纯色都得到同一个哈希，
    于是「两张不同颜色的图」会被判成重复——用它写测试会得出错误结论。
    """
    import numpy as np
    from PIL import Image

    rng = np.random.default_rng(seed)
    Image.fromarray(rng.integers(0, 255, (64, 64, 3), dtype=np.uint8)).save(path)


def test_dedup_marks_rows_and_deletes_files(tmp_path):
    """重复帧要删文件 + 标 dropped，但不删行。

    行留着是有用的：「这段本来选了 30 帧，因为重复只留了 3 张」本身就是信息。
    """
    _textured(tmp_path / "a.jpg", seed=1)
    _textured(tmp_path / "b.jpg", seed=1)
    _textured(tmp_path / "c.jpg", seed=2)

    rows = [{"image": n, "dedup": ""} for n in ("a.jpg", "b.jpg", "c.jpg")]
    dropped = S.dedup_rows(rows, tmp_path, threshold=6)

    assert dropped == 1
    assert [r["dedup"] for r in rows] == ["kept", "dropped", "kept"]
    assert not (tmp_path / "b.jpg").exists(), "被判重复的图要删掉，否则人工还是会看到它"


def test_dedup_keeps_first_occurrence(tmp_path):
    _textured(tmp_path / "first.jpg", seed=7)
    _textured(tmp_path / "second.jpg", seed=7)
    rows = [{"image": "first.jpg", "dedup": ""}, {"image": "second.jpg", "dedup": ""}]
    S.dedup_rows(rows, tmp_path, threshold=6)
    assert rows[0]["dedup"] == "kept"
    assert (tmp_path / "first.jpg").exists()
    assert not (tmp_path / "second.jpg").exists()


def test_dedup_threshold_zero_disables_it(tmp_path):
    rows = [{"image": "a.jpg", "dedup": ""}]
    assert S.dedup_rows(rows, tmp_path, threshold=0) == 0
    assert rows[0]["dedup"] == ""


# ---------------------------------------------------------------- 产物

def test_manifest_has_the_columns_review_depends_on(tmp_path):
    """复核时要能回答「这帧是什么时候的、为哪些类而留、分数多少」。"""
    rows = [{
        "image": "a.jpg", "source_video": "v.mp4", "frame_index": "30",
        "time_sec": "1.00", "n_classes": "3", "top_conf": "0.812",
        "classes": "bin:0.81;bicycle:0.5", "dedup": "kept",
    }]
    path = tmp_path / "manifest.csv"
    S.write_manifest(rows, path)
    got = list(csv.DictReader(path.open(encoding="utf-8")))
    assert got == rows
    assert list(got[0].keys()) == [
        "image", "source_video", "frame_index", "time_sec",
        "n_classes", "top_conf", "classes", "dedup"]


def _tax():
    """桩：真实的 LabelTaxonomy.classes 是 dict 列表（不是对象），桩要一致。"""
    class _T:
        classes = [{"id": 7, "name_en": "bin"},
                   {"id": 11, "name_en": "bicycle"},
                   {"id": 26, "name_en": "fence"}]
    return _T()


def test_report_lists_classes_with_no_candidate(tmp_path):
    """「某类一帧都没扫到」是结论，必须显式写出来。

    不写的话，看报告的人会以为「扫过了，素材里没有」，而真实原因可能是
    零样本模型对该类召回为零（实测 bin 在真实街景上最高只有 0.18）。
    """
    rows = [{"image": "a.jpg", "classes": "bin:0.81", "dedup": "kept"}]
    stats = {"decoded": 100, "sampled": 50, "blur": 5, "candidates": 40,
             "selected": 3, "dedup_dropped": 1}
    args = type("A", (), {"sample_fps": 0.5, "blur_thresh": 100.0,
                          "per_class": 20, "min_score": 0.25, "scan_floor": 0.05,
                          "dedup_threshold": 6})()
    path = tmp_path / "report.md"
    S.write_report(rows, {7: [0.81, 0.5]}, stats, args, path, _tax())
    text = path.read_text(encoding="utf-8")

    assert "| 解码总帧 | 100 |" in text
    assert "| 最终可用 | **1** |" in text
    assert "| bin | 2 | 2 | 0.810 |" in text
    assert "没有任何候选的类别（2 个）" in text
    assert "bicycle" in text and "fence" in text
    assert "候选帧，不是标注" in text
    assert "gdin_threshold" in text, "必须写明不能混用 Grounding DINO 的阈值"
