"""Contradiction checks.

Every entry is a pair of surfaces a real browser keeps in agreement. One
mismatch is survivable; the set of them together is what produces the
'Please Try Again Later' wall.
"""
from __future__ import annotations

from .profile import Profile

MAX_VIEWPORT_SLACK = 2


def consistency(prof: Profile, actual: dict) -> list[str]:
    fails: list[str] = []

    def eq(name: str, want, got, note: str = "") -> None:
        if want != got:
            fails.append(f"{name}: want {want!r} got {got!r}" + (f" ({note})" if note else ""))

    eq("navigator.webdriver", False, actual.get("webdriver"),
       "must be false, not undefined")
    eq("navigator.userAgent", prof.ua, actual.get("ua"))
    eq("navigator.platform", prof.platform, actual.get("platform"))
    eq("hardwareConcurrency", prof.hardware_concurrency, actual.get("cores"))
    eq("deviceMemory", prof.device_memory, actual.get("memory"))
    eq("languages", list(prof.languages), actual.get("languages"))
    eq("maxTouchPoints", prof.touch_points, actual.get("touch"))
    eq("devicePixelRatio", prof.dpr, actual.get("dpr"))
    eq("screen.width", prof.screen_w, actual.get("screen_w"))
    eq("screen.height", prof.screen_h, actual.get("screen_h"))
    eq("screen.availHeight", prof.avail_height, actual.get("avail_h"))
    eq("timezone", prof.timezone, actual.get("tz"))
    eq("webgl vendor", prof.gpu_vendor, actual.get("gl_vendor"))
    eq("webgl renderer", prof.gpu_renderer, actual.get("gl_renderer"))

    if actual.get("canvas_a") != actual.get("canvas_b"):
        fails.append("canvas hash unstable across two reads of the same canvas")

    if isinstance(actual.get("inner_w"), int):
        if abs(actual["inner_w"] - prof.width) > MAX_VIEWPORT_SLACK:
            fails.append(
                f"innerWidth {actual['inner_w']} vs profile {prof.width} "
                "(monitor clamp or zoom mismatch)")
    if isinstance(actual.get("outer_w"), int) and isinstance(actual.get("inner_w"), int):
        if actual["outer_w"] < actual["inner_w"]:
            fails.append("outerWidth < innerWidth")

    if (actual.get("plugins") or 0) < 4:
        fails.append(f"navigator.plugins only {actual.get('plugins')} entries")
    if not actual.get("chrome_runtime"):
        fails.append("window.chrome.runtime missing")
    if actual.get("pdf") is not True:
        fails.append("navigator.pdfViewerEnabled not true")
    if not actual.get("perm_is_eventtarget"):
        fails.append("permissions.query result is not an EventTarget")
    if "native code" not in (actual.get("perm_tostring") or ""):
        fails.append("permissions.query does not stringify as native")

    brands = [b[0] for b in (actual.get("brands") or [])]
    if "Google Chrome" not in brands:
        fails.append(f"userAgentData.brands lacks Google Chrome: {brands}")
    if "Chromium" not in brands:
        fails.append(f"userAgentData.brands lacks Chromium: {brands}")

    return fails