import pytest

from shopee_sniper.drive import parse_price, price_ok, split_variant


@pytest.mark.parametrize("text,want", [
    ("$12.50", 12.5),
    ("1,234.56", 1234.56),
    ("Rp 1.234.567", 1234567.0),
    ("12.500", 12500.0),
    ("8.5", 8.5),
])
def test_parse_price(text: str, want: float) -> None:
    assert parse_price(text) == want


def test_parse_price_rejects_empty() -> None:
    with pytest.raises(ValueError):
        parse_price("n/a")


def test_price_guard_upper_bound() -> None:
    assert price_ok(100.0, 100.0, 0.02)
    assert price_ok(101.0, 100.0, 0.02)
    assert not price_ok(103.0, 100.0, 0.02)


def test_price_guard_allows_discount() -> None:
    assert price_ok(80.0, 100.0, 0.02)


def test_price_guard_without_expectation() -> None:
    assert price_ok(999.0, 0.0, 0.0)
    assert not price_ok(0.0, 0.0, 0.0)


def test_split_variant() -> None:
    assert split_variant("Size: M|Black") == ["Size: M", "Black"]
    assert split_variant(" Red, XL ,") == ["Red", "XL"]
    assert split_variant("") == []