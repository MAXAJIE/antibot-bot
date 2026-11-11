"""Phase 6 sale runner.

Two modes, one code path until the end:

  test  walk to place_order, intercept, abort. No order is created. The captured
        request is written to contract/ so test doubles as Phase 0 capture.
  real  the same walk, then fire the captured request through the sidecar at T0.

--yes skips the confirmation. Nothing is placed without a real-mode race win.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import sys
import time
from pathlib import Path

from .. import contract, settings
from ..bot import BotRuntime
from ..config import load as load_cfg
from ..log import JsonlLog
from ..net.pool import Pool
from ..session.state import Preconditions
from ..settings import Mode
from ..timing import clock
from ..ui.store import Store
from .election import Election
from .race import Participant, Race
from .squad import Squad

REQUIRED_HEADER = "af-ac-enc-dat"


async def prepare(sq: Squad, runtimes: dict[str, BotRuntime],
                  warm_min: int) -> dict[str, int]:
    """Bring bots to ARMED and return their calibrated RTT per bot."""
    live = sq.bind()
    if not live:
        return {}
    rtts: dict[str, int] = {}
    for bot_id in live:
        rtt = await asyncio.to_thread(sq.calibrate, bot_id)
        if rtt is None:
            continue
        rtts[bot_id] = rtt
        sq.ready(bot_id)
        rt = runtimes.get(bot_id)
        if rt:
            if warm_min:
                await rt.warm(warm_min)
            await rt.to_ready()
        sq.arm(bot_id, Preconditions(
            cookies_present=True, spc_f_present=True, cart_staged=True,
            checkout_token_fresh=True, payment_selected=True,
            shipping_selected=True, rtt_samples=sq.cfg.timing.rtt_min_samples,
            rtt_min_samples=sq.cfg.timing.rtt_min_samples))
    return rtts


def save_fixture(got, out: Path) -> None:
    order = [h for h, _ in got.headers]
    doc = {
        "endpoint": "/api/v4/checkout/place_order",
        "method": "POST",
        "header_order": order,
        "headers": {h: v for h, v in got.headers},
        "body": got.body,
        "captured_at": got.at_ms // 1000,
        "ttl_curve": [],
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2))


async def main_async(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--fixture", default="contract/latest.json")
    ap.add_argument("--mode", choices=[m.value for m in Mode], default=None)
    ap.add_argument("--warm-min", type=int, default=0)
    ap.add_argument("--yes", action="store_true")
    a = ap.parse_args(argv)

    cfg = load_cfg(a.config)
    extra = settings.load(a.config)
    dcfg = extra.drive
    if a.mode:
        dcfg = settings.DriveCfg(**{**dcfg.__dict__, "mode": Mode(a.mode)})
    mode = dcfg.mode
    if not dcfg.product_url:
        print("drive.product_url is empty", file=sys.stderr)
        return 1

    log = JsonlLog(f"logs/{mode.value}.jsonl")
    store = Store()
    if extra.ui.enabled:
        from ..ui import console
        srv = console.serve(store, extra.ui.host, extra.ui.port)
        print(f"console http://{extra.ui.host}:{srv.server_port}")

    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    runtimes: dict[str, BotRuntime] = {}
    for i, b in enumerate(cfg.bots):
        runtimes[b.id] = BotRuntime(cfg, b, log, store, dcfg)
        await runtimes[b.id].start(pw, (30 + 620 * (i % 3), 30 + 400 * (i // 3)))

    code = 1
    try:
        sq = Squad(cfg=cfg, log=log, pool=Pool(cfg.proxy.max_p50_ms,
                                              cfg.proxy.preflight_attempts, log))
        rtts = await prepare(sq, runtimes, a.warm_min)
        if not rtts:
            print("no bot reached ready", file=sys.stderr)
            return 1
        print(f"ready: {sorted(rtts)}")
        for bot_id in rtts:
            store.upsert(bot_id, state="READY")

        if mode is Mode.TEST:
            for bot_id, rt in runtimes.items():
                if bot_id not in rtts:
                    continue
                got = await rt.harvest()
                names = [h for h, _ in got.headers]
                ok = REQUIRED_HEADER in names
                print(f"{bot_id}: {len(names)} headers, "
                      f"{REQUIRED_HEADER}={'yes' if ok else 'NO'}, "
                      f"body {len(got.body)}B")
                if ok:
                    save_fixture(got, Path(a.fixture))
            print(f"fixture written to {a.fixture} (ttl_curve empty - unmeasured)")
            code = 0
        else:
            if not a.yes:
                await asyncio.to_thread(input, "press enter to arm and fire ")
            fx = contract.load(a.fixture)
            ttl_safe = 2.0
            if fx.ttl_curve:
                ttl_safe = fx.ttl_safe_s(cfg.harvest.ttl_safety)
            else:
                print("warning: fixture has no ttl_curve, using 2.0s")
            t0 = cfg.sale.t0_ns
            lead = t0 - clock.now_ns() - cfg.harvest.lead_ms * 1_000_000
            if lead > 0:
                print(f"waiting {lead / 1e9:.1f}s to harvest lead")
                clock.sleep_until_ns(t0 - cfg.harvest.lead_ms * 1_000_000)

            parts: list[Participant] = []
            for bot_id, rtt in rtts.items():
                got = await runtimes[bot_id].harvest()
                parts.append(Participant(
                    bot_id=bot_id, conn_id=f"{bot_id}-{int(time.time())}",
                    fixture=fx, rtt_ns=rtt,
                    harvested_at_ms=clock.now_ns() // 1_000_000,
                    session=sq.session(bot_id)))
                store.upsert(bot_id, rtt_ms=rtt / 1e6, ttl_s=ttl_safe)

            el = Election(t0_ns=t0, needle_offset_ms=cfg.timing.needle_offset_ms,
                          jitter_sigma_ms=cfg.timing.jitter_sigma_ms,
                          clamp_ms=cfg.timing.jitter_clamp_ms,
                          rng=random.Random(cfg.sale.item_id))
            race = Race(cfg, log, el, ttl_safe, cfg.sidecar_url,
                        f"shopee.{cfg.sale.region}",
                        cfg.timing.ingest_est_ms * 1_000_000)
            out = await race.run(t0, parts)
            log.write(event="race_done", winner=out.winner,
                      order_id=out.order_id, quorum=out.quorum)
            print(f"winner={out.winner} order={out.order_id} quorum={out.quorum}")
            code = 0 if out.winner else 2
    finally:
        for rt in runtimes.values():
            await rt.close(keep_open=dcfg.keep_open)
        if not dcfg.keep_open:
            await pw.stop()
        else:
            print("browsers left open, ctrl-c to exit")
            await asyncio.to_thread(input, "")
            await pw.stop()
    return code


def main() -> int:
    return asyncio.run(main_async(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())