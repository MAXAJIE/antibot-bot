"""Phase 8 detection.

Markers are structural, not exact strings, because Shopee renames them. When a
fixture in contract/ shows a new shape, add it here and to the test table.
"""
from __future__ import annotations

import enum


class Outcome(enum.Enum):
    OK = "OK"
    BUSY = "BUSY"
    CHALLENGE = "CHALLENGE"
    BANNED = "BANNED"
    FAIL = "FAIL"


CHALLENGE_MARKERS = ("verify/captcha", "captcha", "risk_control", "anti_bot",
                     "riskControl")
BANNED_MARKERS = ("banned", "blocked", "frozen", "account_frozen")
BUSY_MARKERS = ("System busy", "system_busy", "try again later", "too many")


def by_url(url: str) -> bool:
    return "/verify/captcha" in url


def _hit(body: str, markers: tuple[str, ...]) -> bool:
    return any(m in body for m in markers)


def classify(status: int, body: str) -> Outcome:
    if 200 <= status < 300:
        return Outcome.CHALLENGE if _hit(body, CHALLENGE_MARKERS) else Outcome.OK
    if status == 403:
        return Outcome.BANNED if _hit(body, BANNED_MARKERS) else Outcome.CHALLENGE
    if status == 429:
        return Outcome.CHALLENGE
    if 500 <= status < 600:
        return Outcome.BUSY
    if status == 0:
        return Outcome.BUSY
    if _hit(body, CHALLENGE_MARKERS):
        return Outcome.CHALLENGE
    if _hit(body, BUSY_MARKERS):
        return Outcome.BUSY
    return Outcome.FAIL