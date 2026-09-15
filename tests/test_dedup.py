import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from dedup import hamming, is_duplicate  # noqa: E402


def test_hamming_identical_is_zero():
    assert hamming(0b1010, 0b1010) == 0


def test_hamming_counts_differing_bits():
    assert hamming(0b1010, 0b0000) == 2


def test_hamming_symmetric():
    assert hamming(12345, 999) == hamming(999, 12345)


def test_is_duplicate_true_when_within_threshold():
    baseline = 0b1111111111
    assert is_duplicate(0b1111111101, [baseline], threshold=2) is True


def test_is_duplicate_false_when_beyond_threshold():
    baseline = 0b1111111111
    assert is_duplicate(0b0000000000, [baseline], threshold=2) is False


def test_is_duplicate_false_on_empty_seen():
    assert is_duplicate(0b1111, [], threshold=6) is False
