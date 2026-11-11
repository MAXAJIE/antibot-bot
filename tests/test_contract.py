import json

import pytest

from shopee_sniper import contract


def write(tmp_path, **over):
    base = {
        "endpoint": "/api/v4/checkout/place_order",
        "method": "POST",
        "header_order": ["af-ac-enc-dat", "x-csrftoken"],
        "headers": {"af-ac-enc-dat": "abc", "x-csrftoken": "def",
                    "content-type": "application/json", "x-api-source": "pc",
                    "referer": "https://shopee.sg/checkout"},
        "body": "{}",
        "captured_at": 1,
        "ttl_curve": [[0.0, True], [5.0, True], [15.0, False]],
    }
    base.update(over)
    p = tmp_path / "f.json"
    p.write_text(json.dumps(base))
    return p


def test_order_preserved(tmp_path) -> None:
    fx = contract.load(write(tmp_path))
    assert [h for h, _ in fx.ordered_headers()][:2] == ["af-ac-enc-dat", "x-csrftoken"]


def test_order_mismatch_raises(tmp_path) -> None:
    with pytest.raises(ValueError):
        contract.load(write(tmp_path, header_order=["af-ac-enc-dat", "ghost"])).ordered_headers()


def test_ttl_safe(tmp_path) -> None:
    assert contract.load(write(tmp_path)).ttl_safe_s(0.5) == 2.5


def test_lint_flags_missing_ttl(tmp_path) -> None:
    assert any("ttl_curve" in x for x in contract.lint(write(tmp_path, ttl_curve=[])))