from shopee_sniper.observe import headerhash as hh

A = [("content-type", "application/json"), ("af-ac-enc-dat", "x1")]
B = [("af-ac-enc-dat", "x1"), ("content-type", "application/json")]


def test_order_sensitive() -> None:
    assert hh.header_hash(A) != hh.header_hash(B)


def test_value_insensitive() -> None:
    rotated = [("content-type", "application/json"), ("af-ac-enc-dat", "zz9")]
    assert hh.header_hash(A) == hh.header_hash(rotated)


def test_diff_names_drift() -> None:
    out = hh.diff(hh.names(A), hh.names(B))
    assert any("order changed" in line for line in out)


def test_diff_clean() -> None:
    assert hh.diff(hh.names(A), hh.names(A)) == []