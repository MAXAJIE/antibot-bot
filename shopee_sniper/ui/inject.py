"""Phase 7 overlay install.

add_init_script so the HUD survives navigation; the value is pushed from Python
rather than read from the page, so the overlay never reflects stale state.
"""
from __future__ import annotations

from pathlib import Path

from playwright.async_api import Page

OVERLAY = Path(__file__).with_name("overlay.js")


async def install(page: Page, bot_id: str) -> None:
    await page.add_init_script(
        script=OVERLAY.read_text() + f"\nwindow.__HUD_INIT__={{bot_id:'{bot_id}'}};")


async def update(page: Page, data: dict) -> None:
    try:
        await page.evaluate("d => window.__HUD__ && window.__HUD__(d)", data)
    except Exception:
        pass