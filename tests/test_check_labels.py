"""标注质量门禁的判定逻辑。

`validate_line` 现在返回 `(错误, 提示)` 两列。这个区分不是为了好看：

导出工具（Roboflow 等）用浮点写归一化坐标，换算回角点会有 ~1e-6 的残差。
不区分时实测得到「致命错误 75」——其中 **73 个只是取整**、只有 5 个是真越界。
假警报把真问题埋掉：读报告的人要么全部忽略（错过那 5 个），
要么全部当真（无从下手）。

所以这里把两端都钉住：**取整只算提示**、**真越界必须是错误**。
"""
from check_labels import OOB_TOLERANCE, missing_label_fatals, parse_box, validate_line

N = 16


def errs(line: str) -> list[str]:
    return validate_line(line, N)[0]


def notes(line: str) -> list[str]:
    return validate_line(line, N)[1]


# ---------- 缺标签 ----------

def test_all_missing_labels_is_fatal():
    msgs = missing_label_fatals(10, 10)
    assert msgs and "全部图像" in msgs[0]


def test_majority_missing_labels_is_fatal():
    msgs = missing_label_fatals(10, 5)
    assert msgs and "超过半数" in msgs[0]


def test_few_missing_labels_is_not_fatal():
    assert missing_label_fatals(10, 2) == []
    assert missing_label_fatals(10, 0) == []


# ---------- 基本合法性 ----------

def test_valid_line_has_neither_errors_nor_notes():
    assert validate_line("0 0.5 0.5 0.2 0.2", N) == ([], [])


def test_wrong_field_count_is_error():
    assert errs("0 0.5 0.5 0.2") != []


def test_non_numeric_is_error():
    assert errs("0 abc 0.5 0.2 0.2") != []


def test_class_id_out_of_range_is_error():
    assert errs("16 0.5 0.5 0.2 0.2") != []
    assert errs("-1 0.5 0.5 0.2 0.2") != []


def test_coordinate_out_of_range_is_error():
    assert errs("0 1.5 0.5 0.2 0.2") != []
    assert errs("0 0.5 0.5 0.2 -0.1") != []


def test_zero_size_box_is_error():
    assert errs("0 0.5 0.5 0.0 0.2") != []


def test_parse_box_returns_tuple():
    assert parse_box("3 0.25 0.75 0.1 0.2") == (3, 0.25, 0.75, 0.1, 0.2)


def test_parse_box_returns_none_on_bad_input():
    assert parse_box("nonsense") is None


# ---------- 框越界：取整 vs 真越界 ----------

def test_real_overflow_is_error():
    # cx=0.95, w=0.2 -> x2=1.05，超出 0.05，远超容差
    assert errs("0 0.95 0.5 0.2 0.2") != []


def test_borderline_rounding_is_only_a_note():
    """实测里最常见的情形：x2 = 1.0000000000000002 之类。

    它必须**不是**错误 —— 否则报告会被几百条无害告警淹没。
    """
    # cx=0.9, w=0.2 -> x2=1.0 正好在边界；用 0.9000000000000001 造出 1e-16 级的溢出
    line = "0 0.9000000000000001 0.5 0.2 0.2"
    assert errs(line) == [], f"边界取整不该算错误，却报了 {errs(line)}"
    # 允许"正好在边界"时既无错误也无提示（浮点可能刚好等于 1.0）
    assert validate_line(line, N) == ([], []) or notes(line)


def test_rounding_note_is_reported_but_not_as_error():
    """溢出量远小于容差时：有提示、无错误。"""
    # 让 x2 = 1 + 5e-6：cx = 0.9 + 2.5e-6, w = 0.2
    line = "0 0.9000025 0.5 0.2 0.2"
    e, n = validate_line(line, N)
    assert e == [], f"5e-6 的溢出不该算错误：{e}"
    assert n, "应给出「边界取整」提示，否则这类数据会被静默忽略"


def test_overflow_just_over_tolerance_is_error():
    """跨过容差就必须升级为错误——这条守着「阈值不能太松」。

    若把容差放到让 0.02 的溢出也通过，那 20230127_182724_mp4 那批
    真实越界（最大 0.12）就会被放行。
    """
    over = OOB_TOLERANCE * 1.5
    # w = 0.2, cx 使 x2 = 1 + over
    cx = 1.0 + over - 0.1
    line = f"0 {cx} 0.5 0.2 0.2"
    assert errs(line) != [], f"超出容差 {over} 应算错误"


def test_tolerance_is_neither_too_tight_nor_too_loose():
    """容差本身也得钉住：太紧会把取整当错误，太松会放过真越界。"""
    # 实测残差最大约 1e-3 以内；真实越界最小约 2e-2。
    # 容差必须落在这个空隙里。
    assert OOB_TOLERANCE >= 1e-5, "太紧：浮点残差会被当成错误"
    assert OOB_TOLERANCE <= 5e-3, "太松：真实越界会被放过"
