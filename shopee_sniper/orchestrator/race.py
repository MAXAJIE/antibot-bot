"""Phase 6 race: N bots, one needle, one winner.

A shot already in flight cannot be recalled; the planbook accepts cross-account
duplicates and simply does not pay them. The halt controls one thing: no new
shot starts once a winner exists.
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from typing import Any, Callable

from .. import contract
from ..captcha.detect import Outcome, classify
from ..config import Config
from ..log import JsonlLog
from ..session.state import Session, State
from ..timing import clock
from ..timing.fire import ShotResult, backoff_ms, fire, should_retry
from .election import Election

FireFn = Callable[["Participant", int], ShotResult]


@dataclass
class Participant:
    bot_id: str
    conn_id: str
    fixture: contract.Fixture
    rtt_ns: int
    harvested_at_ms: int
    session: Session

    def ttl_remaining_s(self, ttl_safe_s: float) -> float:
        age_s = (clock.now_ns() // 1_000_000 - self.harvested_at_ms) / 1000.0
        return ttl_safe_s - age_s


@dataclass
class RaceOutcome:
    winner: str | None = None
    order_id: str | None = None
    shots: list[tuple[str, int]] = field(default_factory=list)
    aborted: bool = False
    quorum: bool = False


def order_id(body: str) -> str | None:
    try:
        doc: Any = json.loads(body)
    except (TypeError, ValueError):
        return None
    if not isinstance(doc, dict):
        return None
    for holder in (doc, doc.get("data")):
        if not isinstance(holder, dict):
            continue
        for key in ("order_id", "ordersn", "order_sn"):
            v = holder.get(key)
            if v not in (None, "", 0):
                return str(v)
    return None


class Race:
    def __init__(self, cfg: Config, log: JsonlLog, election: Election,
                 ttl_safe_s: float, sidecar_url: str, host: str, ingest_ns: int,
                 fire_fn: FireFn | None = None, hard_timeout_s: float = 25.0) -> None:
        self.cfg = cfg
        self.log = log
        self.election = election
        self.ttl_safe_s = ttl_safe_s
        self.sidecar_url = sidecar_url
        self.host = host
        self.ingest_ns = ingest_ns
        self.fire_fn = fire_fn
        self.hard_timeout_s = hard_timeout_s

    async def run(self, t0_ns: int, parts: list[Participant]) -> RaceOutcome:
        out = RaceOutcome()
        if not parts:
            return out
        offsets = self.election.offsets_ns([p.bot_id for p in parts])
        halt = asyncio.Event()
        tasks = [asyncio.create_task(self._one(p, offsets[p.bot_id], halt, out))
                 for p in parts]
        done, pending = await asyncio.wait(tasks, timeout=self.hard_timeout_s)
        if pending:
            out.aborted = True
            self.log.write(event="race_timeout", pending=len(pending))
            for t in pending:
                t.cancel()
        for t in done:
            exc = t.exception()
            if exc is not None:
                self.log.write(event="race_error", error=repr(exc))
        challenged = sum(1 for p in parts if p.session.state is State.CHALLENGED)
        out.quorum = self.election.quorum_abort(challenged, len(parts))
        if out.quorum and out.winner is None:
            out.aborted = True
            self.log.write(event="quorum_abort", challenged=challenged,
                           total=len(parts))
        return out

    async def _one(self, p: Participant, target_ns: int, halt: asyncio.Event,
                   out: RaceOutcome) -> None:
        if halt.is_set():
            self.log.write(bot_id=p.bot_id, event="race_skip", reason="halted")
            return
        if p.ttl_remaining_s(self.ttl_safe_s) <= 0:
            p.session.disarm("ttl expired before fire")
            self.log.write(bot_id=p.bot_id, event="race_skip", reason="ttl")
            return
        p.session.fire()
        while True:
            res = await asyncio.to_thread(self._fire, p, target_ns)
            out.shots.append((p.bot_id, res.status))
            if res.ok:
                oid = order_id(res.body)
                if oid:
                    won = self.election.report(p.bot_id, oid)
                    if won:
                        out.winner, out.order_id = p.bot_id, oid
                        halt.set()
                        self.log.write(bot_id=p.bot_id, event="winner", order_id=oid)
                    p.session.placed(oid)
                    return
            kind = classify(res.status, res.body)
            if kind is Outcome.CHALLENGE:
                p.session.challenge("place_order")
                self.log.write(bot_id=p.bot_id, event="challenged", status=res.status)
                return
            if kind is Outcome.BANNED:
                p.session.ban("403")
                self.log.write(bot_id=p.bot_id, event="banned")
                return
            if halt.is_set() or not should_retry(res, p.session.retries,
                                                 self.cfg.limits.retry_cap):
                p.session.fail(f"status {res.status}")
                self.log.write(bot_id=p.bot_id, event="give_up", status=res.status)
                return
            p.session.retries += 1
            delay = backoff_ms(self.cfg.limits.retry_backoff_ms, p.session.retries)
            self.log.write(bot_id=p.bot_id, event="retry", status=res.status,
                           attempt=p.session.retries, delay_ms=delay)
            await asyncio.sleep(delay / 1000)
            target_ns = clock.now_ns() + 200_000

    def _fire(self, p: Participant, target_ns: int) -> ShotResult:
        if self.fire_fn is not None:
            return self.fire_fn(p, target_ns)
        # fire() subtracts rtt/2 + ingest itself; hand back the T0 that puts the
        # actual send on target_ns.
        return fire(p.conn_id, p.fixture,
                    t0_ns=target_ns + p.rtt_ns // 2 + self.ingest_ns,
                    rtt_ns=p.rtt_ns, ingest_ns=self.ingest_ns,
                    sidecar_url=self.sidecar_url, host=self.host,
                    log=self.log, bot_id=p.bot_id)