"""Contradiction checks.

Every entry is a pair of surfaces a real browser keeps in agreement. One
mismatch is survivable; the set of them together is what produces the
'Please Try Again Later' wall.
"""
from __future__ import annotations

import re

from .profile import Profile

_UA_BUILD = re.compile(r"Chrome/\d+\.\d+\.\d+\.\d+")


def _ua_core(ua: str) -> str:
    """Collapse the Chrome build to its reduced form before comparing.

    Chrome's UA reduction means the wire UA says major.0.0.0 while the binary
    knows a full build. An exact string compare fails on every point release for
    no reason. Collapsing still catches a wrong major, a wrong platform, and a
    Chromium-for-Chrome swap, which is what the check is actually for.
    """
    return _UA_BUILD.sub("Chrome/#", ua or "")

MAX_VIEWPORT_SLACK = 2


def _brand_names(raw) -> list[str]:
    """navigator.userAgentData.brands serialises to a list of dicts, but a
    hand-written fixture may use pairs or bare strings. Accept all three."""
    out: list[str] = []
    for entry in raw or []:
        if isinstance(entry, dict):
            out.append(str(entry.get("brand") or ""))
        elif isinstance(entry, (list, tuple)):
            out.append(str(entry[0]) if entry else "")
        else:
            out.append(str(entry))
    return [b for b in out if b]


def consistency(prof: Profile, actual: dict) -> list[str]:
    fails: list[str] = []

    def eq(name: str, want, got, note: str = "") -> None:
        if want != got:
            fails.append(f"{name}: want {want!r} got {got!r}"
                         + (f" ({note})" if note else ""))

    eq("navigator.webdriver", False, actual.get("webdriver"),
       "must be false, not undefined")
    got_ua = actual.get("ua") or ""
    if _ua_core(got_ua) != _ua_core(prof.ua):
        fails.append(f"navigator.userAgent: want {prof.ua!r} got {got_ua!r}")
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

    brands = _brand_names(actual.get("brands"))
    if not brands:
        fails.append("navigator.userAgentData.brands empty or absent")
    else:
        if "Google Chrome" not in brands:
            fails.append(f"userAgentData.brands lacks Google Chrome: {brands}")
        if "Chromium" not in brands:
            fails.append(f"userAgentData.brands lacks Chromium: {brands}")

    return fails