"""Gate 6. Election and offset distribution, offline.

The fake fire returns a winner on one bot and a bare 200 elsewhere, which is
exactly the shape the race has to resolve without charging twice.
"""
from __future__ import annotations

import argparse
import asyncio
import random
import time

from shopee_sniper import contract
from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race
from shopee_sniper.session.state import Preconditions, Session
from shopee_sniper.timing.fire import ShotResult


def armed(bot_id: str) -> Session:
    s = Session(bot_id=bot_id)
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def fake(winner: str):
    def fn(p: Participant, target_ns: int) -> ShotResult:
        now = time.time_ns()
        body = '{"order_id":"A1"}' if p.bot_id == winner else '{"ok":true}'
        return ShotResult(200, body, now, now, target_ns, 0.0, 1_000_000)
    return fn


async def run(bots: int, winner: str) -> int:
    cfg = load("config/bots.example.yaml")
    log = JsonlLog("logs/election.jsonl")
    t0 = time.time_ns() + 400_000_000
    el = Election(t0_ns=t0, needle_offset_ms=cfg.timing.needle_offset_ms,
                  jitter_sigma_ms=cfg.timing.jitter_sigma_ms,
                  clamp_ms=cfg.timing.jitter_clamp_ms, rng=random.Random(3))
    ids = [f"bot{i:02d}" for i in range(1, bots + 1)]
    offs = el.offsets_ns(ids)
    spread = sorted((o - t0) // 1_000_000 for o in offs.values())
    print(f"offsets ms {spread}")
    fx = contract.Fixture(endpoint="/api/v4/checkout/place_order", method="POST",
                          header_order=("content-type",),
                          headers={"content-type": "application/json"},
                          body="{}", captured_at=int(time.time()),
                          ttl_curve=((1.0, True),))
    parts = [Participant(bot_id=i, conn_id=i, fixture=fx, rtt_ns=1_000_000,
                         harvested_at_ms=time.time_ns() // 1_000_000,
                         session=armed(i)) for i in ids]
    race = Race(cfg, log, el, 30.0, "http://127.0.0.1:8731", "shopee.sg",
                25_000_000, fire_fn=fake(winner))
    out = await race.run(t0, parts)
    placed = sum(1 for p in parts if p.session.state.value == "PLACED")
    print(f"winner={out.winner} order={out.order_id} shots={len(out.shots)} "
          f"placed={placed}")
    return 0 if out.winner == winner and placed == 1 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", type=int, default=6)
    ap.add_argument("--winner", default="bot03")
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.bots, a.winner))


if __name__ == "__main__":
    raise SystemExit(main())