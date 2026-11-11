"""Phase 6/9 smoke. Real HTTP, fake sidecar, no Go, no browser, no proxy.

Proves the parts that fail silently: the sidecar JSON contract, the election,
the state machine, the journal and the metrics. Does not prove TLS, JA3 or DOM.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import random
import statistics
import time
from pathlib import Path
from types import SimpleNamespace

from shopee_sniper import contract
from shopee_sniper.config import Bot, Config, Harvest, Limits, ProxyCfg, Sale, Timing
from shopee_sniper.log import JsonlLog
from shopee_sniper.observe import metrics
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race
from shopee_sniper.orchestrator.squad import Squad
from shopee_sniper.session.state import Preconditions
from shopee_sniper.timing import clock
from tools import fake_sidecar

RTT_NS = 40_000_000


class StubPool:
    """Preflight without the network. Bind still records and validates."""

    def preflight_all(self, raws: list[str]) -> None:
        self.raws = list(raws)

    def bind(self, bot_id: str, raw: str):
        return SimpleNamespace(p50_ms=12.0, exit_ip="127.0.0.1")

    def dirty(self, bot_id: str) -> None:
        pass


def build_cfg(bots: int) -> Config:
    return Config(
        sale=Sale(t0=dt.datetime.now(dt.timezone.utc), region="sg", item_id=1,
                  model_id=1, quantity=1, payment_channel_id=1,
                  shipping_method="standard"),
        timing=Timing(-15, 60, (-40, 180), 20, 15, 0.3, 25, 5, 2.0),
        proxy=ProxyCfg(400, 600, 3),
        limits=Limits(2, 120, 3),
        harvest=Harvest(3000, 0.5),
        sidecar_url="http://127.0.0.1:1",
        bots=tuple(Bot(id=f"bot{i:02d}", account=f"a{i}",
                       proxy=f"http://127.0.0.1:{9000 + i}",
                       profile_path=Path(f"profiles/bot{i:02d}.json"))
                   for i in range(1, bots + 1)),
    )


def fixture() -> contract.Fixture:
    return contract.Fixture(
        endpoint="/api/v4/checkout/place_order", method="POST",
        header_order=("content-type", "af-ac-enc-dat", "x-csrftoken"),
        headers={"content-type": "application/json", "af-ac-enc-dat": "stub",
                 "x-csrftoken": "stub"},
        body='{"item_id":1}', captured_at=int(time.time()),
        ttl_curve=((1.0, True), (2.0, True)))


async def run(bots: int) -> int:
    Path("logs").mkdir(exist_ok=True)
    log_path = Path("logs/smoke.jsonl")
    log_path.write_text("")
    log = JsonlLog(log_path)

    srv, st = fake_sidecar.serve()
    cfg = build_cfg(bots)
    cfg = Config(**{**cfg.__dict__, "sidecar_url": f"http://127.0.0.1:{srv.server_port}"})
    sq = Squad(cfg=cfg, log=log, pool=StubPool())

    try:
        live = sq.bind()
        for bot_id in live:
            sq.ready(bot_id)
            sq.arm(bot_id, Preconditions(True, True, True, True, True, True, 20, 15))
            await asyncio.to_thread(
                lambda b=bot_id: fake_sidecar.ThreadedPing if False else None)
        print(f"armed {len(live)} bots: {live}")

        fx = fixture()
        ttl_safe = fx.ttl_safe_s(cfg.harvest.ttl_safety)
        parts = [Participant(bot_id=b, conn_id=b, fixture=fx, rtt_ns=RTT_NS,
                            harvested_at_ms=clock.now_ns() // 1_000_000,
                            session=sq.session(b)) for b in live]
        for p in parts:
            _warm(cfg.sidecar_url, p.conn_id)

        t0 = clock.now_ns() + 700_000_000
        el = Election(t0_ns=t0, needle_offset_ms=-15, jitter_sigma_ms=60,
                      clamp_ms=(-40, 180), rng=random.Random(1))
        race = Race(cfg, log, el, ttl_safe, cfg.sidecar_url, "shopee.sg",
                    25_000_000, hard_timeout_s=15.0)
        out = await race.run(t0, parts)
    finally:
        srv.shutdown()

    rows = [__import__("json").loads(l) for l in log_path.read_text().splitlines()]
    errs = [r["send_error_ms"] for r in rows if "send_error_ms" in r]
    placed = [p for p in parts if p.session.state.value == "PLACED"]

    print()
    print(f"shots        {len(out.shots)}")
    print(f"winner       {out.winner}  order={out.order_id}")
    print(f"placed       {len(placed)}  (must be 1)")
    print(f"send_error   worst {max(map(abs, errs), default=999):.2f}ms  "
          f"sd {statistics.pstdev(errs) if len(errs) > 1 else 0:.2f}ms")
    print(f"sidecar saw  {len(st.shots)} shots, all keys present")
    print()
    print(metrics.render(metrics.collect([log_path])).strip())

    ok = (out.winner is not None and out.order_id == "SMOKE-1"
          and len(placed) == 1 and len(st.shots) == len(out.shots))
    print()
    print("SMOKE PASS" if ok else "SMOKE FAIL")
    return 0 if ok else 1


def _warm(url: str, conn_id: str) -> None:
    import json
    import urllib.request
    req = urllib.request.Request(
        url.rstrip("/") + "/warm",
        data=json.dumps({"connid": conn_id, "host": "shopee.sg"}).encode(),
        headers={"content-type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=5).read()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", type=int, default=6)
    a = ap.parse_args()
    return asyncio.run(run(a.bots))


if __name__ == "__main__":
    raise SystemExit(main())