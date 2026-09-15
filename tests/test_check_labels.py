from check_labels import parse_box, validate_line

N = 16


def test_valid_line_has_no_errors():
    assert validate_line("0 0.5 0.5 0.2 0.2", N) == []


def test_wrong_field_count_is_error():
    assert validate_line("0 0.5 0.5 0.2", N) != []


def test_non_numeric_is_error():
    assert validate_line("0 abc 0.5 0.2 0.2", N) != []


def test_class_id_out_of_range_is_error():
    assert validate_line("16 0.5 0.5 0.2 0.2", N) != []
    assert validate_line("-1 0.5 0.5 0.2 0.2", N) != []


def test_coordinate_out_of_range_is_error():
    assert validate_line("0 1.5 0.5 0.2 0.2", N) != []
    assert validate_line("0 0.5 0.5 0.2 -0.1", N) != []


def test_zero_size_box_is_error():
    assert validate_line("0 0.5 0.5 0.0 0.2", N) != []


def test_parse_box_returns_tuple():
    assert parse_box("3 0.25 0.75 0.1 0.2") == (3, 0.25, 0.75, 0.1, 0.2)


def test_parse_box_returns_none_on_bad_input():
    assert parse_box("nonsense") is None


def test_box_exceeding_image_bounds_is_error():
    # cx=0.95, w=0.2 -> x2=1.05 越界
    assert validate_line("0 0.95 0.5 0.2 0.2", N) != []
