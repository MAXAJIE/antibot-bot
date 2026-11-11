"""Phase 3 behavioural warm-up. Zero-input sessions get challenged.

Two changes from the old version: the landing is verified rather than assumed,
and the input is no longer scroll-only. A session that never focuses, never
types and never leaves the homepage has a shape nothing human produces.
"""
from __future__ import annotations

import asyncio
import random

from playwright.async_api import Page

from ..captcha.detect import Outcome, classify_page


class Blocked(RuntimeError):
    def __init__(self, outcome: Outcome) -> None:
        super().__init__(f"blocked on arrival: {outcome.value}")
        self.outcome = outcome


async def _dwell(lo_ms: int, hi_ms: int) -> None:
    await asyncio.sleep(random.uniform(lo_ms, hi_ms) / 1000.0)


async def _human_move(page: Page, to_x: float, to_y: float) -> None:
    await page.mouse.move(to_x, to_y, steps=random.randint(8, 24))


async def probe(page: Page) -> Outcome:
    try:
        html = await page.content()
    except Exception:
        return Outcome.OK
    return classify_page(page.url, html)


async def _focus_dance(page: Page, rng: random.Random) -> None:
    """Real sessions blur and refocus. Constant focus is a tell."""
    await page.evaluate("() => window.dispatchEvent(new Event('focus'))")
    await _dwell(400, 1200)
    await page.evaluate(
        "() => { const b = document.body; b && b.dispatchEvent("
        "new MouseEvent('mousemove', {bubbles: true, clientX: 4, clientY: 4})); }")
    await _dwell(200, 700)


async def _type_search(page: Page, rng: random.Random) -> None:
    """Focus the search box and type a few characters, then Escape."""
    box = page.locator('input[type="search"], input[name="keyword"], '
                       'input[class*="search"]').first
    try:
        if not await box.count() or not await box.is_visible():
            return
        await box.click(timeout=2500)
        await _dwell(300, 900)
        for ch in rng.choice(("phone", "case", "cable", "lamp", "mouse")):
            await page.keyboard.type(ch)
            await asyncio.sleep(rng.uniform(0.06, 0.19))
        await _dwell(500, 1400)
        await page.keyboard.press("Escape")
    except Exception:
        pass


async def warm(page: Page, base: str, minutes: int, rng: random.Random) -> None:
    await page.goto(base, wait_until="domcontentloaded")
    await _dwell(1400, 2800)

    verdict = await probe(page)
    if verdict in (Outcome.HARD_BLOCK, Outcome.BANNED):
        raise Blocked(verdict)

    await _focus_dance(page, rng)
    await _type_search(page, rng)

    for _ in range(rng.randint(3, 6)):
        await page.mouse.wheel(0, rng.randint(280, 900))
        await _dwell(400, 1500)

    tiles = await page.query_selector_all('a[data-sqe="link"]')
    for tile in tiles[: rng.randint(4, 8)]:
        try:
            box = await tile.bounding_box()
            if not box:
                continue
            await _human_move(page, box["x"] + box["width"] / 2,
                              box["y"] + box["height"] / 2)
            await _dwell(700, 2400)
        except Exception:
            continue

    await page.keyboard.press("Escape")
    await _dwell(600, 1400)

    deadline = asyncio.get_event_loop().time() + minutes * 60
    while asyncio.get_event_loop().time() < deadline:
        await page.mouse.wheel(0, rng.randint(-400, 400))
        await _dwell(3000, 9000)
        if rng.random() < 0.2:
            await page.keyboard.press("Home")
        if rng.random() < 0.15:
            await page.reload(wait_until="domcontentloaded")
            await _dwell(1500, 3000)
            verdict = await probe(page)
            if verdict is Outcome.HARD_BLOCK:
                raise Blocked(verdict)