"""Phase 3 behavioural warm-up. Zero-input sessions get challenged."""
from __future__ import annotations

import asyncio
import random

from playwright.async_api import Page


async def _dwell(lo_ms: int, hi_ms: int) -> None:
    await asyncio.sleep(random.uniform(lo_ms, hi_ms) / 1000.0)


async def _human_move(page: Page, to_x: float, to_y: float) -> None:
    await page.mouse.move(to_x, to_y, steps=random.randint(8, 24))


async def warm(page: Page, base: str, minutes: int, rng: random.Random) -> None:
    await page.goto(base, wait_until="domcontentloaded")
    await _dwell(1200, 2600)

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
        if rng.random() < 0.15:
            await page.reload(wait_until="domcontentloaded")
            await _dwell(1500, 3000)