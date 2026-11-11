"""Gate 8. Dress rehearsal with no network: scheduler, election, no double charge.

Fake fire sleeps to the absolute target and reports the real send instant, so
send error is measured through the same code path a live shot uses.
"""
from __future__ import annotations

import argparse
import asyncio
import random
import statistics
import time

from shopee_sniper import contract
from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race
from shopee_sniper.session.state import Preconditions, Session
from shopee_sniper.timing import clock
from shopee_sniper.timing.fire import ShotResult


def armed(bot_id: str) -> Session:
    s = Session(bot_id=bot_id)
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def fake(winner: str, errs: list[float]):
    def fn(p: Participant, target_ns: int) -> ShotResult:
        clock.sleep_until_ns(target_ns)
        sent = time.time_ns()
        errs.append((sent - target_ns) / 1e6)
        body = '{"order_id":"A1"}' if p.bot_id == winner else '{"ok":true}'
        return ShotResult(200, body, sent, sent, target_ns, errs[-1], 1_000_000)
    return fn


async def run(bots: int) -> int:
    cfg = load("config/bots.example.yaml")
    log = JsonlLog("logs/rehearsal.jsonl")
    t0 = time.time_ns() + 600_000_000
    el = Election(t0_ns=t0, needle_offset_ms=cfg.timing.needle_offset_ms,
                  jitter_sigma_ms=cfg.timing.jitter_sigma_ms,
                  clamp_ms=cfg.timing.jitter_clamp_ms, rng=random.Random(11))
    ids = [f"bot{i:02d}" for i in range(1, bots + 1)]
    fx = contract.Fixture(endpoint="/api/v4/checkout/place_order", method="POST",
                          header_order=("content-type",),
                          headers={"content-type": "application/json"},
                          body="{}", captured_at=int(time.time()),
                          ttl_curve=((1.0, True),))
    parts = [Participant(bot_id=i, conn_id=i, fixture=fx, rtt_ns=1_000_000,
                         harvested_at_ms=time.time_ns() // 1_000_000,
                         session=armed(i)) for i in ids]
    errs: list[float] = []
    race = Race(cfg, log, el, 30.0, "http://127.0.0.1:8731", "shopee.sg",
                25_000_000, fire_fn=fake("bot02", errs))
    out = await race.run(t0, parts)
    placed = sum(1 for p in parts if p.session.state.value == "PLACED")
    worst = max(abs(e) for e in errs) if errs else 999
    sd = statistics.pstdev(errs) if len(errs) > 1 else 0.0
    print(f"winner={out.winner} shots={len(out.shots)} placed={placed} "
          f"worst_send_err={worst:.2f}ms sd={sd:.2f}ms")
    return 0 if out.winner and placed == 1 and worst <= 15 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", type=int, default=6)
    a = ap.parse_args()
    return asyncio.run(run(a.bots))


if __name__ == "__main__":
    raise SystemExit(main())