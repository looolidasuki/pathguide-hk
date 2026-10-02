"""Dart 类别表生成器。

类别索引是 YOLO 的标签契约。Dart 侧如果手抄一份，任何错位都会让 App
安静地标错类别（不报错）。所以这里断言生成结果与 configs/classes.json 一致。
"""
import json
import pathlib
import re

import pytest

import gen_dart_labels as G


def test_loads_all_classes_from_single_source():
    """从 configs/classes.json 读 —— 断言「与单一来源一致」，不是某个具体数字。

    先前这里硬编码 48，每次扩表都要手改测试。而真正的不变式是
    「Dart 侧与 classes.json 逐项相同」，与类数无关。
    """
    classes = G.load_classes()
    assert classes, "类别表为空"
    assert [c["id"] for c in classes] == list(range(len(classes)))

    src = json.loads((pathlib.Path(G.REPO_ROOT) / "configs" / "classes.json")
                     .read_text(encoding="utf-8"))["classes"]
    assert len(classes) == len(src)
    assert [(c["id"], c["name_en"]) for c in classes] == \
           [(c["id"], c["name_en"]) for c in src]


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
    classes = G.load_classes()
    dart = G.render_dart(classes)
    assert f"const int kNumClasses = {len(classes)};" in dart, \
        f"Dart 里的类别数应与 classes.json 的 {len(classes)} 一致"


def test_dart_output_preserves_id_to_name_mapping():
    """逐个核对 id -> nameEn，错位是这里最危险的失败模式。"""
    classes = G.load_classes()
    dart = G.render_dart(classes)
    blocks = re.findall(r"Label\(\s*id: (\d+),\s*nameEn: '([^']+)',\s*"
                        r"nameZh: '([^']+)',", dart)
    assert len(blocks) == len(classes)
    for (cid, en, zh), c in zip(blocks, classes):
        assert int(cid) == c["id"]
        assert en == c["name_en"]
        assert zh == c["name_zh"]


def test_known_anchors_are_correct():
    """抽查几个已知锚点，防止整表被平移。"""
    dart = G.render_dart(G.load_classes())
    assert re.search(r"id: 6,\s*nameEn: 'pedestrian'", dart)
    assert re.search(r"id: 7,\s*nameEn: 'bin'", dart)
    assert re.search(r"id: 13,\s*nameEn: 'push_cart'", dart)
    assert re.search(r"id: 23,\s*nameEn: 'fork_in_road'", dart)
    assert re.search(r"id: 47,\s*nameEn: 'bucket'", dart)


def test_unannounced_classes_are_announced_false():
    """announced=false 的类不该被播报。

    v3 之后有两个：streetlight(45) 与 sign_post(46)——两者到处都有、
    对用户**不可行动**，播报只会把真正该说的话挤掉。
    """
    dart = G.render_dart(G.load_classes())
    for cid, name in ((45, "streetlight"), (46, "sign_post")):
        block = re.search(rf"Label\(\s*id: {cid},.*?announced: (\w+),", dart, re.S)
        assert block, f"id {cid}（{name}）没找到"
        assert block.group(1) == "false", f"{name} 应当 announced=false"


def test_p0_classes_come_before_p1_in_announcement_order():
    classes = G.load_classes()
    order = G.announcement_order(classes)
    rank = {c["id"]: (0 if c.get("announced", True) else 1,
                      G.PRIORITY_RANK.get(c.get("priority", "P2"), 2))
            for c in classes}
    ranks = [rank[i] for i in order]
    assert ranks == sorted(ranks), "播报顺序必须 announced 优先、再按 P0→P1"


def test_unannounced_class_is_last_in_order():
    """不播报的类排在最后。

    v3 之后有两个这样的类，所以断言「最后两个是不播报的集合」而不是
    某个固定 id——写死单个 id 会在下次扩表时变成一条没有意义的失败。
    """
    classes = G.load_classes()
    order = G.announcement_order(classes)
    unannounced = {c["id"] for c in classes if not c.get("announced", True)}
    assert unannounced == {45, 46}
    assert set(order[-len(unannounced):]) == unannounced


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


def test_txt_list_is_in_id_order_not_sorted():
    """classes.txt 的行序 = 类别索引，给 X-AnyLabeling 用。

    这是**曾经漂移过**的一处第二事实源：它当初手抄，v3 扩表后仍是旧内容，
    而标注工具的配置正好读它。所以现在由生成器产出并断言顺序。
    """
    classes = G.load_classes()
    txt = G.render_txt(classes)
    lines = txt.splitlines()
    assert lines == [c["name_en"] for c in classes]
    assert lines[7] == "bin", "第 8 行（索引 7）必须是 bin"


def test_txt_is_regenerated_alongside_dart(tmp_path, monkeypatch):
    target_txt = tmp_path / "classes.txt"
    monkeypatch.setattr(G, "TXT_PATH", target_txt)
    monkeypatch.setattr(G, "DART_PATH", tmp_path / "labels.dart")
    monkeypatch.setattr(G, "JSON_PATH", tmp_path / "labels.json")
    assert G.write_outputs(check=False) == 0
    assert target_txt.exists()
    n = len(G.load_classes())
    assert len(target_txt.read_text(encoding="utf-8").splitlines()) == n
    # check 模式应当认为已同步（三个产物都刚写过）
    assert G.write_outputs(check=True) == 0


def test_check_mode_reports_out_of_sync_without_writing(tmp_path, monkeypatch, capsys):
    target_dart = tmp_path / "labels.dart"
    target_json = tmp_path / "labels.json"
    monkeypatch.setattr(G, "DART_PATH", target_dart)
    monkeypatch.setattr(G, "JSON_PATH", target_json)
    monkeypatch.setattr(G, "TXT_PATH", tmp_path / "classes.txt")
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


