"""Phase 5 pool. One proxy per bot, never shared, latency-ranked."""
from __future__ import annotations

from dataclasses import dataclass, field

from ..log import JsonlLog
from .proxy import Preflight, parse, preflight


@dataclass
class Pool:
    max_p50_ms: int
    attempts: int
    log: JsonlLog
    _results: dict[str, Preflight] = field(default_factory=dict)
    _bound: dict[str, str] = field(default_factory=dict)

    def preflight_all(self, raw_list: list[str]) -> None:
        for raw in raw_list:
            try:
                px = parse(raw)
            except ValueError as exc:
                self.log.write(event="proxy_parse_fail", raw=raw, error=str(exc))
                continue
            pf = preflight(px, self.max_p50_ms, self.attempts)
            self._results[px.raw] = pf
            self.log.write(event="preflight", proxy=px.host, ok=pf.ok,
                           p50_ms=round(pf.p50_ms, 1), exit_ip=pf.exit_ip)

    def bind(self, bot_id: str, raw: str) -> Preflight:
        """Sticky bind. Refuses to rebind a bot already holding a proxy."""
        if bot_id in self._bound:
            return self._results[self._bound[bot_id]]
        pf = self._results[raw]
        if not pf.eligible:
            raise RuntimeError(f"proxy ineligible for {bot_id}: {pf.p50_ms:.0f}ms")
        self._bound[bot_id] = raw
        return pf

    def dirty(self, bot_id: str) -> None:
        raw = self._bound.pop(bot_id, None)
        if raw and raw in self._results:
            self._results[raw].ok = False
        self.log.write(event="proxy_dirty", bot_id=bot_id, proxy=raw)

    def eligible(self) -> list[Preflight]:
        used = set(self._bound.values())
        return sorted(
            (pf for pf in self._results.values()
             if pf.eligible and pf.proxy.raw not in used),
            key=lambda pf: pf.p50_ms,
        )