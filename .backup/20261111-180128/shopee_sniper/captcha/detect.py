"""Challenge classification.

Two distinct failures live behind the same URL:

  HARD  /verify/captcha renders 'Please Try Again Later' with no slider. The
        session was rejected outright; the token is dead and a 120ms retry
        re-uses a burned context. Needs a cooldown and an IP quarantine.
  SOFT  a real slider is on the page. That is solvable in place.

The old classifier had no HARD case and matched on the substring 'captcha',
so every hard block was routed to a slider solver that was not present.
"""
from __future__ import annotations

import enum


class Outcome(enum.Enum):
    OK = "OK"
    BUSY = "BUSY"
    CHALLENGE = "CHALLENGE"
    HARD_BLOCK = "HARD_BLOCK"
    BANNED = "BANNED"
    FAIL = "FAIL"


HARD_MARKERS = (
    "Please Try Again Later",
    "try again after a few minutes",
    "anti_bot_tracking_id",
    "anti_bot",
    "risk_control_challenge",
    "riskControlChallenge",
)
CHALLENGE_MARKERS = (
    "verify/captcha",
    "slider-handle",
    "captcha-slider",
    "captcha-bg",
    "captcha-puzzle",
)
BANNED_MARKERS = ("account_frozen", "account frozen", "frozen", "banned",
                  "permanently blocked")
BUSY_MARKERS = ("System busy", "system_busy", "too many requests")


def by_url(url: str) -> bool:
    return "/verify/captcha" in url


def _hit(body: str, markers: tuple[str, ...]) -> bool:
    return any(m in body for m in markers)


def classify_page(url: str, html: str) -> Outcome:
    """Page-level verdict. HARD is checked before the slider markers because a
    hard block page still carries 'captcha' in its URL."""
    if _hit(html, BANNED_MARKERS):
        return Outcome.BANNED
    if _hit(html, HARD_MARKERS) and not _hit(html, ("slider-handle", "captcha-bg")):
        return Outcome.HARD_BLOCK
    if _hit(html, CHALLENGE_MARKERS) or by_url(url):
        return Outcome.CHALLENGE
    return Outcome.OK


def classify(status: int, body: str) -> Outcome:
    """Response-level verdict for a fired shot."""
    if 200 <= status < 300:
        if _hit(body, HARD_MARKERS):
            return Outcome.HARD_BLOCK
        return Outcome.CHALLENGE if _hit(body, CHALLENGE_MARKERS) else Outcome.OK
    if status == 403:
        if _hit(body, BANNED_MARKERS):
            return Outcome.BANNED
        if _hit(body, HARD_MARKERS):
            return Outcome.HARD_BLOCK
        return Outcome.CHALLENGE
    if status == 429:
        return Outcome.HARD_BLOCK
    if 500 <= status < 600:
        return Outcome.BUSY
    if status == 0:
        return Outcome.BUSY
    if _hit(body, HARD_MARKERS):
        return Outcome.HARD_BLOCK
    if _hit(body, CHALLENGE_MARKERS):
        return Outcome.CHALLENGE
    if _hit(body, BUSY_MARKERS):
        return Outcome.BUSY
    return Outcome.FAIL