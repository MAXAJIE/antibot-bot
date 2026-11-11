"""Challenge classification.

Two distinct failures live behind the same URL:

  HARD  /verify/captcha renders 'Please Try Again Later' with no slider. The
        session was rejected outright; the token is dead and a 120ms retry
        re-uses a burned context. Needs a cooldown and an IP quarantine.
  SOFT  a real slider is on the page. That is solvable in place.

Page classification keys off the URL first. Shopee inlines its whole JS bundle,
so a substring match against page.content() hits 'risk_control' and 'captcha' on
every page - markers are only consulted as a fallback.

API classification is separate: an API body carries identifiers, not CSS class
names, so it gets its own marker set and a leading order-id short-circuit.
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


# Rendered text, not bundle identifiers.
HARD_TEXT = (
    "Please Try Again Later",
    "try again after a few minutes",
    "Please try again later",
)
# DOM markers, only trusted on the challenge page itself.
SLIDER_MARKERS = (
    "slider-handle",
    "captcha-slider",
    "captcha-bg",
    "captcha-puzzle",
)
BANNED_MARKERS = ("account_frozen", "account frozen", "frozen", "banned",
                  "permanently blocked")
BUSY_MARKERS = ("System busy", "system_busy", "too many requests")
ORDER_MARKERS = ('"order_id"', '"ordersn"', '"order_sn"')
# API bodies carry identifiers. Kept apart from SLIDER_MARKERS so a page bundle
# full of class names cannot match through this path.
API_CHALLENGE_MARKERS = ("risk_control", "riskControl", "captcha", "anti_bot",
                         "verify_captcha")


def by_url(url: str) -> bool:
    return "/verify/captcha" in url


def _hit(body: str, markers: tuple[str, ...]) -> bool:
    return any(m in body for m in markers)


def _has_order(body: str) -> bool:
    return _hit(body, ORDER_MARKERS)


def classify_page(url: str, html: str) -> Outcome:
    """Page-level verdict.

    Off the challenge URL, only a slider or the explicit card counts. On the
    challenge URL, the absence of a slider *is* the verdict - no marker needed.
    """
    if by_url(url):
        if _hit(html, SLIDER_MARKERS):
            return Outcome.CHALLENGE
        if _hit(html, BANNED_MARKERS):
            return Outcome.BANNED
        return Outcome.HARD_BLOCK
    if _hit(html, SLIDER_MARKERS):
        return Outcome.CHALLENGE
    if _hit(html, HARD_TEXT):
        return Outcome.HARD_BLOCK
    if _hit(html, BANNED_MARKERS):
        return Outcome.BANNED
    return Outcome.OK


def classify(status: int, body: str) -> Outcome:
    """Response-level verdict for a fired shot.

    A body carrying an order id is a success even when it also mentions
    anti_bot_tracking_id, which Shopee attaches to plenty of healthy responses.
    """
    if 200 <= status < 300:
        if _has_order(body):
            return Outcome.OK
        if _hit(body, HARD_TEXT):
            return Outcome.HARD_BLOCK
        if _hit(body, API_CHALLENGE_MARKERS):
            return Outcome.CHALLENGE
        return Outcome.OK
    if status == 403:
        if _hit(body, BANNED_MARKERS):
            return Outcome.BANNED
        if _hit(body, HARD_TEXT):
            return Outcome.HARD_BLOCK
        return Outcome.CHALLENGE
    if status == 429:
        return Outcome.HARD_BLOCK
    if 500 <= status < 600:
        return Outcome.BUSY
    if status == 0:
        return Outcome.BUSY
    if _hit(body, HARD_TEXT):
        return Outcome.HARD_BLOCK
    if _hit(body, API_CHALLENGE_MARKERS) or _hit(body, SLIDER_MARKERS):
        return Outcome.CHALLENGE
    if _hit(body, BUSY_MARKERS):
        return Outcome.BUSY
    return Outcome.FAIL