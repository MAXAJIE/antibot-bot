"""Phase 8 slider solver.

Gap from Canny edges, drag as a cubic ease-out with one overshoot and a settle
correction, dispatched as real CDP mouse events. A low-confidence gap is
re-fetched rather than dragged blind, and a degenerate image (no edges) is
rejected instead of being matched at a meaningless 1.0.
"""
from __future__ import annotations

import asyncio
import random

import cv2
import numpy as np
from playwright.async_api import CDPSession, Page

SCORE_MIN = 0.35
MIN_EDGE_PX = 24


class LowScore(RuntimeError):
    pass


def _decode(raw: bytes) -> np.ndarray:
    img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("undecodable image")
    return img


def _edges(img: np.ndarray) -> np.ndarray:
    return cv2.Canny(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), 100, 200)


def _edge_count(edges: np.ndarray) -> int:
    return int(edges.sum()) // 255


def gap(bg: bytes, puzzle: bytes, score_min: float = SCORE_MIN) -> tuple[int, float]:
    g = _edges(_decode(bg))
    p = _edges(_decode(puzzle))
    if p.shape[0] > g.shape[0] or p.shape[1] > g.shape[1]:
        p = cv2.resize(p, (min(p.shape[1], g.shape[1]), min(p.shape[0], g.shape[0])))
    if _edge_count(g) < MIN_EDGE_PX:
        raise LowScore(f"background has {_edge_count(g)} edge px")
    if _edge_count(p) < MIN_EDGE_PX:
        raise LowScore(f"puzzle has {_edge_count(p)} edge px")
    r = cv2.matchTemplate(g, p, cv2.TM_CCOEFF_NORMED)
    _, score, _, loc = cv2.minMaxLoc(r)
    if score < score_min:
        raise LowScore(f"match {score:.3f} < {score_min}")
    return loc[0], score


def curve(dist: int, rng: random.Random | None = None) -> list[tuple[float, float]]:
    r = rng or random.Random()
    steps = r.randint(28, 45)
    pts: list[tuple[float, float]] = []
    for i in range(steps):
        t = i / (steps - 1)
        pts.append((dist * (1 - (1 - t) ** 3), r.uniform(-1.0, 1.0)))
    over = r.randint(3, 6)
    pts.append((dist + over, 0.0))
    pts.append((dist + over - r.randint(2, 4), r.uniform(-0.5, 0.5)))
    pts.append((dist, 0.0))
    return pts


def delays(n: int, total_ms: int = 800, rng: random.Random | None = None) -> list[float]:
    """Per-step sleeps: 8-25ms, rescaled to land near total_ms."""
    r = rng or random.Random()
    raw = [r.uniform(8, 25) for _ in range(n)]
    k = total_ms / sum(raw)
    return [min(25.0, max(8.0, v * k)) for v in raw]


async def drag(cdp: CDPSession, x0: float, y0: float,
               pts: list[tuple[float, float]], rng: random.Random | None = None,
               total_ms: int = 800) -> None:
    await cdp.send("Input.dispatchMouseEvent", {
        "type": "mousePressed", "x": x0, "y": y0, "button": "left",
        "clickCount": 1, "buttons": 1})
    waits = delays(len(pts), total_ms, rng)
    for (dx, dy), wait in zip(pts, waits):
        await cdp.send("Input.dispatchMouseEvent", {
            "type": "mouseMoved", "x": x0 + dx, "y": y0 + dy, "button": "left",
            "buttons": 1})
        await asyncio.sleep(wait / 1000)
    await cdp.send("Input.dispatchMouseEvent", {
        "type": "mouseReleased", "x": x0 + pts[-1][0], "y": y0,
        "button": "left", "clickCount": 1, "buttons": 0})


async def solve(page: Page, cdp: CDPSession, bg_sel: str, puzzle_sel: str,
                handle_sel: str, success_sel: str = "",
                shift_px: int = 0, score_min: float = SCORE_MIN,
                rng: random.Random | None = None) -> bool:
    bg = await page.locator(bg_sel).screenshot()
    puzzle = await page.locator(puzzle_sel).screenshot()
    dist, _ = gap(bg, puzzle, score_min)
    box = await page.locator(handle_sel).bounding_box()
    if box is None:
        raise LowScore("handle not laid out")
    pts = curve(dist + shift_px, rng)
    await drag(cdp, box["x"] + box["width"] / 2, box["y"] + box["height"] / 2, pts, rng)
    if not success_sel:
        return True
    try:
        await page.wait_for_selector(success_sel, timeout=3000, state="detached")
        return True
    except Exception:
        return False