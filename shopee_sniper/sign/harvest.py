"""Phase 2. Let the page sign for us.

At T-lead the page fires a genuine place_order through the Shopee axios
interceptor, which attaches af-ac-enc-dat. We capture headers + body at the CDP
layer and ABORT so no order is placed.

Fail, never continue: continuing places a real order and burns the shot.
"""
from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass

from playwright.async_api import CDPSession, Page


@dataclass
class Harvested:
    headers: list[tuple[str, str]]
    body: str
    at_ms: int

    def age_s(self) -> float:
        return (int(time.time() * 1000) - self.at_ms) / 1000.0

    def fresh(self, ttl_safe_s: float) -> bool:
        return self.age_s() <= ttl_safe_s


class HarvestError(RuntimeError):
    pass


async def harvest(cdp: CDPSession, page: Page, url_pat: str = "*place_order*",
                  timeout_s: float = 8.0) -> Harvested:
    held: dict = {}
    done = asyncio.Event()

    def on_paused(ev: dict) -> None:
        req = ev.get("request", {})
        if req.get("method") != "POST":
            asyncio.ensure_future(
                cdp.send("Fetch.continueRequest", {"requestId": ev["requestId"]}))
            return
        if held:
            asyncio.ensure_future(
                cdp.send("Fetch.failRequest",
                         {"requestId": ev["requestId"], "errorReason": "Aborted"}))
            return
        held["headers"] = list(req.get("headers", {}).items())
        held["body"] = req.get("postData", "")
        held["at_ms"] = int(time.time() * 1000)
        done.set()
        asyncio.ensure_future(
            cdp.send("Fetch.failRequest",
                     {"requestId": ev["requestId"], "errorReason": "Aborted"}))

    cdp.on("Fetch.requestPaused", on_paused)
    await cdp.send("Fetch.enable", {"patterns": [
        {"urlPattern": url_pat, "requestStage": "Request"}]})
    try:
        await trigger_checkout(page)
        await asyncio.wait_for(done.wait(), timeout=timeout_s)
    except asyncio.TimeoutError as exc:
        raise HarvestError(f"no place_order intercepted in {timeout_s}s") from exc
    finally:
        cdp.off("Fetch.requestPaused", on_paused)
        await cdp.send("Fetch.disable")

    if not held.get("headers"):
        raise HarvestError("intercepted request carried no headers")
    return Harvested(headers=held["headers"], body=held["body"], at_ms=held["at_ms"])


async def trigger_checkout(page: Page) -> None:
    """Fire the page checkout path. Prefer the API over clicking."""
    await page.evaluate("""
      () => {
        const btn = document.querySelector('[data-testid="checkout-button"]')
                 || document.querySelector('button.checkout-button')
                 || document.querySelector('button[class*="checkout"]');
        if (btn) { btn.scrollIntoView({block:'center'}); btn.click(); return; }
        const a = document.querySelector('a[href*="checkout"]');
        if (a) { a.click(); return; }
        throw new Error('checkout trigger not found');
      }
    """)