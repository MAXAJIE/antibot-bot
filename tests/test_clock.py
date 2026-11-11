from shopee_sniper.timing.clock import fire_instant, now_ns, sleep_until

NS = 1_000_000_000


def test_fire_instant_halves_rtt() -> None:
    t0 = 10 * NS
    assert fire_instant(t0, 100_000_000, 25_000_000) == t0 - 75_000_000


def test_sleep_until_overshoot_bounded() -> None:
    target = now_ns() + 40_000_000
    over = sleep_until(target)
    assert -0.5 <= over <= 3.0