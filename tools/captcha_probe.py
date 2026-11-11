"""Gate: can this identity and this exit IP load Shopee without a wall?

Navigates the homepage, optionally a product page, and reports the verdict.
Exit 0 means OK or a solvable slider. This is the cheapest way to test a bypass
change - no sale, no sidecar, no timing.

    python -m tools.captcha_probe --config config/bots.yaml --product
"""
from __future__ import annotations

import argparse
import asyncio

from shopee_sniper import config, settings
from shopee_sniper.bot import BotRuntime
from shopee_sniper.captcha.detect import Outcome
from shopee_sniper.log import JsonlLog
from shopee_sniper.session import warmup
from shopee_sniper.settings import DriveCfg
from shopee_sniper.ui.store import Store


async def run(config_path: str, product: bool, keep: bool) -> int:
    cfg = config.load(config_path)
    extra = settings.load(config_path)
    log = JsonlLog("logs/probe.jsonl")
    store = Store()
    bot = cfg.bots[0]
    rt = BotRuntime(cfg, bot, log, store, DriveCfg())

    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    verdict = Outcome.FAIL
    try:
        await rt.start(pw, (60, 60))
        await rt.land()
        await asyncio.sleep(3)
        verdict = await warmup.probe(rt.page)
        print(f"homepage  {verdict.value}")
        if product and verdict is Outcome.OK and extra.drive.product_url:
            await rt.page.goto(extra.drive.product_url,
                               wait_until="domcontentloaded")
            await asyncio.sleep(3)
            verdict = await warmup.probe(rt.page)
            print(f"product   {verdict.value}")
        print(f"\nurl  {rt.page.url}")
        if verdict is Outcome.HARD_BLOCK:
            print("\n  HARD BLOCK - identity or exit IP. Run fpcheck, then check the ASN.")
        elif verdict is Outcome.CHALLENGE:
            print("\n  slider present - identity accepted, solvable.")
    except warmup.Blocked as exc:
        verdict = exc.outcome
        print(f"blocked on arrival: {verdict.value}")
    finally:
        await rt.close(keep_open=keep)
        if keep:
            await asyncio.to_thread(input, "enter to close ")
        await pw.stop()
    return 0 if verdict in (Outcome.OK, Outcome.CHALLENGE) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--product", action="store_true")
    ap.add_argument("--keep-open", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.config, a.product, a.keep_open))


if __name__ == "__main__":
    raise SystemExit(main())