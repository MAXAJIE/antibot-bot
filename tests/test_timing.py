from shopee_sniper.timing.fire import ShotResult, backoff_ms, should_retry
from shopee_sniper.timing.rtt import trimmed_p50


def shot(status: int, body: str = "") -> ShotResult:
    return ShotResult(status, body, 0, 0, 0, 0.0, 0)


def test_retry_on_5xx_only() -> None:
    assert should_retry(shot(503), 0, 2)
    assert should_retry(shot(200, "System busy"), 0, 2)
    assert not should_retry(shot(400), 0, 2)
    assert not should_retry(shot(403), 0, 2)


def test_retry_cap() -> None:
    assert not should_retry(shot(503), 2, 2)


def test_trimmed_p50_drops_outliers() -> None:
    assert trimmed_p50([10, 11, 12, 13, 12, 900, 11, 12]) == 12


def test_backoff_grows() -> None:
    assert backoff_ms(120, 2) > backoff_ms(120, 1)