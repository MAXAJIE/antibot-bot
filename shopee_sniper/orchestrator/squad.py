"""Phase 6 squad. One account, one proxy, one bot, one profile directory.

The squad owns the boring gates so the race only has to fire: proxy binding,
RTT calibration, ARMED bookkeeping, quorum and ban accounting.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..config import Bot, Config
from ..log import JsonlLog
from ..net.pool import Pool
from ..session.state import Preconditions, Session, State
from ..timing.rtt import RttTracker


@dataclass
class Squad:
    cfg: Config
    log: JsonlLog
    pool: Pool
    _sessions: dict[str, Session] = field(default_factory=dict)
    _rtt: dict[str, RttTracker] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for b in self.cfg.bots:
            self._sessions[b.id] = Session(bot_id=b.id)

    def session(self, bot_id: str) -> Session:
        return self._sessions[bot_id]

    def host(self, bot: Bot) -> str:
        return f"shopee.{self.cfg.sale.region}"

    def bind(self) -> list[str]:
        """Pre-flight every proxy, bind survivors, arm a tracker each."""
        self.pool.preflight_all([b.proxy for b in self.cfg.bots])
        live: list[str] = []
        for b in self.cfg.bots:
            try:
                pf = self.pool.bind(b.id, b.proxy)
            except (KeyError, RuntimeError) as exc:
                self.log.write(bot_id=b.id, event="proxy_ineligible", error=str(exc))
                continue
            self._rtt[b.id] = RttTracker(host=self.host(b),
                                         alpha=self.cfg.timing.rtt_ewma_alpha,
                                         samples=self.cfg.timing.rtt_samples)
            self.log.write(bot_id=b.id, event="proxy_bound",
                           p50_ms=round(pf.p50_ms, 1), exit_ip=pf.exit_ip)
            live.append(b.id)
        return live

    def calibrate(self, bot_id: str) -> int | None:
        tr = self._rtt[bot_id]
        rtt = tr.refresh()
        ok = tr.eligible(self.cfg.timing.rtt_min_samples)
        self.log.write(bot_id=bot_id, event="rtt", ewma_ms=round(rtt / 1e6, 2),
                       p50_ms=round(tr.p50_ms(), 2), eligible=ok)
        return rtt if ok else None

    def ready(self, bot_id: str) -> None:
        s = self._sessions[bot_id]
        if s.state is State.COLD:
            s.warm()
        if s.state is State.WARMING:
            s.ready()

    def arm(self, bot_id: str, pre: Preconditions) -> None:
        s = self._sessions[bot_id]
        s.pre = pre
        if s.state is State.READY:
            s.arm()

    def armed(self) -> list[Bot]:
        return [b for b in self.cfg.bots
                if self._sessions[b.id].state is State.ARMED]

    def note_challenge(self, bot_id: str) -> bool:
        """True when the quorum abort threshold is crossed."""
        challenged = sum(1 for s in self._sessions.values()
                         if s.state is State.CHALLENGED)
        return challenged / len(self._sessions) > 0.5

    def note_ban(self, bot_id: str) -> None:
        self._sessions[bot_id].ban("banned")
        self.pool.dirty(bot_id)
        self.log.write(bot_id=bot_id, event="banned")