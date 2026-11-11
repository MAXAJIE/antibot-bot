"""Drive the browser to the place-order button with no timing and no sidecar.

This is the selector workbench: run it after any Shopee UI change, read which
step fails, fix config/selectors.json, run again. --mode test also writes the
captured request to a fixture.
"""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

from shopee_sniper import contract, settings
from shopee_sniper.bot import BotRuntime
from shopee_sniper.config import load as load_cfg
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.run import save_fixture
from shopee_sniper.ui.store import Store


async def run(config: str, mode: str, fixture: str, keep: bool) -> int:
    cfg = load_cfg(config)
    extra = settings.load(config)
    dcfg = settings.DriveCfg(**{**extra.drive.__dict__,
                                "mode": settings.Mode(mode), "keep_open": keep})
    log = JsonlLog("logs/drive.jsonl")
    store = Store()
    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    bot = cfg.bots[0]
    rt = BotRuntime(cfg, bot, log, store, dcfg)
    code = 1
    try:
        await rt.start(pw, (60, 60))
        total = await rt.to_ready()
        print(f"reached place-order, total={total!r}")
        if dcfg.mode is settings.Mode.TEST:
            got = await rt.harvest()
            names = [h for h, _ in got.headers]
            print(f"captured {len(names)} headers, body {len(got.body)}B")
            print("has af-ac-enc-dat:", "af-ac-enc-dat" in names)
            save_fixture(got, Path(fixture))
            print(f"fixture -> {fixture}")
        code = 0
    except Exception as exc:
        print(f"FAILED at {store.snapshot()['bots'].get(bot.id, {}).get('last_event')}: {exc}")
    finally:
        await rt.close(keep_open=keep)
        if keep:
            await asyncio.to_thread(input, "enter to close ")
        await pw.stop()
    return code


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--mode", choices=["test", "real"], default="test")
    ap.add_argument("--fixture", default="contract/latest.json")
    ap.add_argument("--keep-open", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.config, a.mode, a.fixture, a.keep_open))


if __name__ == "__main__":
    raise SystemExit(main())