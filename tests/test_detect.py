from shopee_sniper.captcha.detect import Outcome, by_url, classify


def test_ok() -> None:
    assert classify(200, '{"order_id":1}') is Outcome.OK


def test_captcha_url() -> None:
    assert by_url("https://shopee.sg/verify/captcha/get?x=1")


def test_challenge_in_body() -> None:
    assert classify(200, '{"error":"risk_control"}') is Outcome.CHALLENGE


def test_banned() -> None:
    assert classify(403, '{"msg":"account frozen"}') is Outcome.BANNED


def test_403_without_marker_is_challenge() -> None:
    assert classify(403, "forbidden") is Outcome.CHALLENGE


def test_busy_and_fail() -> None:
    assert classify(503, "System busy") is Outcome.BUSY
    assert classify(400, "bad") is Outcome.FAIL