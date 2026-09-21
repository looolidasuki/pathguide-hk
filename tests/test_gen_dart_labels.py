"""Dart 类别表生成器。

类别索引是 YOLO 的标签契约。Dart 侧如果手抄一份，任何错位都会让 App
安静地标错类别（不报错）。所以这里断言生成结果与 configs/classes.json 一致。
"""
import json
import re

import pytest

import gen_dart_labels as G


def test_loads_all_24_classes_from_single_source():
    classes = G.load_classes()
    assert len(classes) == 24
    assert [c["id"] for c in classes] == list(range(24))


def test_class_ids_are_continuous_starting_at_zero():
    """YOLO 输出维度即类别数，id 不连续就说明类别表坏了。"""
    classes = G.load_classes()
    assert [c["id"] for c in classes] == list(range(len(classes)))


def test_rejects_non_continuous_ids(tmp_path):
    bad = tmp_path / "classes.json"
    bad.write_text(json.dumps({"classes": [
        {"id": 0, "name_en": "a", "name_zh": "甲"},
        {"id": 2, "name_en": "b", "name_zh": "乙"},
    ]}), encoding="utf-8")
    with pytest.raises(ValueError, match="连续整数"):
        G.load_classes(bad)


def test_dart_output_declares_the_right_class_count():
    dart = G.render_dart(G.load_classes())
    assert "const int kNumClasses = 24;" in dart


def test_dart_output_preserves_id_to_name_mapping():
    """逐个核对 id -> nameEn，错位是这里最危险的失败模式。"""
    classes = G.load_classes()
    dart = G.render_dart(classes)
    blocks = re.findall(r"Label\(\s*id: (\d+),\s*nameEn: '([^']+)',\s*"
                        r"nameZh: '([^']+)',", dart)
    assert len(blocks) == 24
    for (cid, en, zh), c in zip(blocks, classes):
        assert int(cid) == c["id"]
        assert en == c["name_en"]
        assert zh == c["name_zh"]


def test_known_anchors_are_correct():
    """抽查几个已知锚点，防止整表被平移。"""
    dart = G.render_dart(G.load_classes())
    assert re.search(r"id: 6,\s*nameEn: 'pedestrian'", dart)
    assert re.search(r"id: 7,\s*nameEn: 'bin'", dart)
    assert re.search(r"id: 23,\s*nameEn: 'ambiguous_vertical'", dart)


def test_ambiguous_vertical_is_not_announced():
    """训练期占位类不该被播报，否则会念出一个语义空洞的类别。"""
    dart = G.render_dart(G.load_classes())
    block = re.search(r"Label\(\s*id: 23,.*?announced: (\w+),", dart, re.S)
    assert block and block.group(1) == "false"


def test_p0_classes_come_before_p1_in_announcement_order():
    classes = G.load_classes()
    order = G.announcement_order(classes)
    rank = {c["id"]: (0 if c.get("announced", True) else 1,
                      G.PRIORITY_RANK.get(c.get("priority", "P2"), 2))
            for c in classes}
    ranks = [rank[i] for i in order]
    assert ranks == sorted(ranks), "播报顺序必须 announced 优先、再按 P0→P1"


def test_unannounced_class_is_last_in_order():
    order = G.announcement_order(G.load_classes())
    assert order[-1] == 23


def test_announcement_order_covers_every_class_once():
    classes = G.load_classes()
    order = G.announcement_order(classes)
    assert sorted(order) == [c["id"] for c in classes]


def test_dart_escapes_single_quotes():
    """类别名里若出现单引号，生成的 Dart 必须是合法字符串字面量。"""
    dart = G.render_dart([{"id": 0, "name_en": "o'brien", "name_zh": "甲",
                           "group": "g", "priority": "P0", "announced": True}])
    assert r"nameEn: 'o\'brien'" in dart


def test_json_output_matches_dart_source():
    classes = G.load_classes()
    payload = json.loads(G.render_json(classes))
    assert payload["num_classes"] == len(classes)
    assert [x["id"] for x in payload["labels"]] == [c["id"] for c in classes]
    assert [x["name_en"] for x in payload["labels"]] == [c["name_en"] for c in classes]


def test_check_mode_reports_out_of_sync_without_writing(tmp_path, monkeypatch, capsys):
    target_dart = tmp_path / "labels.dart"
    target_json = tmp_path / "labels.json"
    monkeypatch.setattr(G, "DART_PATH", target_dart)
    monkeypatch.setattr(G, "JSON_PATH", target_json)
    rc = G.write_outputs(check=True)
    assert rc == 1
    assert not target_dart.exists()
    assert "不同步" in capsys.readouterr().out


def test_check_mode_passes_when_already_synced(tmp_path, monkeypatch, capsys):
    target_dart = tmp_path / "labels.dart"
    target_json = tmp_path / "labels.json"
    monkeypatch.setattr(G, "DART_PATH", target_dart)
    monkeypatch.setattr(G, "JSON_PATH", target_json)
    assert G.write_outputs(check=False) == 0
    assert G.write_outputs(check=True) == 0
    assert "已同步" in capsys.readouterr().out
