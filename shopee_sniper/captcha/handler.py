"""Phase 8 challenge handler.

One attempt, one shifted-curve retry, then the operator gets it. Budget is per
bot per sale and lives on the Session, so a bot cannot grind forever.
"""
from __future__ import annotations

from playwright.async_api import CDPSession, Page

from ..log import JsonlLog
from ..session.state import Session
from ..settings import CaptchaCfg, OtpCfg
from ..ui.store import Store
from . import otp, slider

BG = "#captcha-bg, .captcha-bg, canvas"
PUZZLE = "#captcha-puzzle, .captcha-puzzle"
HANDLE = ".slider-handle, .captcha-slider__handle, [class*='slider-handle']"
SUCCESS = ".captcha-wrapper, .verify-captcha"


async def handle(page: Page, cdp: CDPSession, session: Session, store: Store,
                 log: JsonlLog, bot_id: str, cap: CaptchaCfg,
                 otp_cfg: OtpCfg | None = None) -> bool:
    if not cap.enabled:
        return False
    if session.challenges_used >= 3:
        log.write(bot_id=bot_id, event="challenge_budget_spent")
        store.handoff(bot_id, "budget spent")
        return False

    try:
        if await page.locator("input[maxlength='1'], input[type='tel']").count() \
                and otp_cfg and otp_cfg.enabled:
            code = await otp.wait_code(otp_cfg)
            await otp.submit(page, code)
            log.write(bot_id=bot_id, event="otp_submitted")
            return True
    except Exception as exc:
        log.write(bot_id=bot_id, event="otp_failed", error=repr(exc))

    for attempt, shift in enumerate((0, cap.retry_shift_px)):
        try:
            ok = await slider.solve(page, cdp, BG, PUZZLE, HANDLE, SUCCESS, shift_px=shift)
        except slider.LowScore as exc:
            log.write(bot_id=bot_id, event="slider_low_score", error=str(exc),
                      attempt=attempt)
            continue
        except Exception as exc:
            log.write(bot_id=bot_id, event="slider_error", error=repr(exc),
                      attempt=attempt)
            continue
        log.write(bot_id=bot_id, event="slider_result", ok=ok, attempt=attempt)
        if ok:
            return True
        await page.wait_for_timeout(cap.settle_ms)

    store.handoff(bot_id, "slider failed twice")
    return False