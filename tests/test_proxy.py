import pytest

from shopee_sniper.net.proxy import parse


def test_parse_full() -> None:
    p = parse("http://u:p@host.example:8080")
    assert (p.host, p.port, p.user, p.password) == ("host.example", 8080, "u", "p")


def test_parse_bare() -> None:
    assert parse("host.example:8080").port == 8080


def test_parse_encodes_credentials() -> None:
    p = parse("http://u%40x:p%3Aw@h:1")
    assert p.user == "u@x" and p.password == "p:w"


def test_parse_rejects() -> None:
    with pytest.raises(ValueError):
        parse("nohost")