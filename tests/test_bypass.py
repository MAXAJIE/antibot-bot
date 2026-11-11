from shopee_sniper.captcha.detect import Outcome, classify, classify_page
from shopee_sniper.fingerprint import gate
from shopee_sniper.fingerprint.profile import Profile

HARD_HTML = ("<div>Please Try Again Later</div>"
             "<div>Please try again after a few minutes.</div>")
SLIDER_HTML = '<div class="captcha-bg"></div><div class="slider-handle"></div>'


def test_hard_block_beats_slider_marker() -> None:
    """The block page carries 'captcha' in its URL. It must not be routed to a
    slider solver that is not on the page."""
    assert classify_page(
        "https://x/verify/captcha?anti_bot_tracking_id=1",
        HARD_HTML) is Outcome.HARD_BLOCK


def test_slider_page_is_challenge() -> None:
    assert classify_page("https://x/verify/captcha", SLIDER_HTML) is Outcome.CHALLENGE


def test_clean_page_is_ok() -> None:
    assert classify_page("https://shopee.my/", "<div>home</div>") is Outcome.OK


def test_403_hard_marker() -> None:
    assert classify(403, HARD_HTML) is Outcome.HARD_BLOCK


def test_429_is_hard() -> None:
    assert classify(429, "") is Outcome.HARD_BLOCK


def test_frozen_still_banned() -> None:
    assert classify(403, "account frozen") is Outcome.BANNED


def _prof() -> Profile:
    return Profile(
        seed="b1", ua="UA", chrome_major=131, chrome_version="131.0.6778.86",
        platform="Win32", ch_platform="Windows", width=1600, height=900,
        screen_w=1920, screen_h=1080, dpr=1.0, locale="en-MY",
        timezone="Asia/Kuala_Lumpur", gpu_vendor="Google Inc. (NVIDIA)",
        gpu_renderer="ANGLE (NVIDIA)", hardware_concurrency=8, device_memory=8,
        canvas_seed=1, audio_seed=2, languages=("en-MY", "en"))


def _actual(**over) -> dict:
    base = dict(webdriver=False, ua="UA", platform="Win32", cores=8, memory=8,
                languages=["en-MY", "en"], touch=0, dpr=1.0, screen_w=1920,
                screen_h=1080, avail_h=1032, inner_w=1584, outer_w=1600,
                tz="Asia/Kuala_Lumpur", gl_vendor="Google Inc. (NVIDIA)",
                gl_renderer="ANGLE (NVIDIA)", canvas_a="a", canvas_b="a",
                plugins=5, chrome_runtime=True, pdf=True,
                perm_is_eventtarget=True,
                perm_tostring="function query() { [native code] }",
                brands=[{"brand": "Chromium"}, {"brand": "Not_A Brand"},
                        {"brand": "Google Chrome"}])
    base.update(over)
    return base


def test_clean_profile_passes() -> None:
    assert gate.consistency(_prof(), _actual()) == []


def test_webdriver_undefined_fails() -> None:
    assert any("webdriver" in f
               for f in gate.consistency(_prof(), _actual(webdriver=None)))


def test_unstable_canvas_fails() -> None:
    assert any("canvas" in f for f in gate.consistency(_prof(), _actual(canvas_b="b")))


def test_swiftshader_fails() -> None:
    out = gate.consistency(_prof(), _actual(gl_renderer="ANGLE (Google, Vulkan SwiftShader)"))
    assert any("renderer" in f for f in out)


def test_missing_chrome_brand_fails() -> None:
    out = gate.consistency(_prof(), _actual(brands=[{"brand": "Chromium"}]))
    assert any("Google Chrome" in f for f in out)


def test_screen_mismatch_fails() -> None:
    assert any("screen.width" in f
               for f in gate.consistency(_prof(), _actual(screen_w=1366)))


def test_permissions_not_eventtarget_fails() -> None:
    assert any("EventTarget" in f
               for f in gate.consistency(_prof(), _actual(perm_is_eventtarget=False)))


def test_equal_inner_outer_fails() -> None:
    """A forced viewport erases the window frame."""
    assert any("frame" in f
               for f in gate.consistency(_prof(), _actual(inner_w=1600, outer_w=1600)))