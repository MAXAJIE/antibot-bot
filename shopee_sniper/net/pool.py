"""Phase 5 pool. One proxy per bot, never shared, latency-ranked, reputation-gated."""
from __future__ import annotations

from dataclasses import dataclass, field

from ..log import JsonlLog
from . import ipintel
from .proxy import Preflight, parse, preflight


@dataclass
class Pool:
    max_p50_ms: int
    attempts: int
    log: JsonlLog
    require_residential: bool = False
    allow_countries: tuple[str, ...] = ()
    region: str = ""
    _results: dict[str, Preflight] = field(default_factory=dict)
    _bound: dict[str, str] = field(default_factory=dict)
    _quarantined: set[str] = field(default_factory=set)

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
        if raw in self._quarantined:
            raise RuntimeError(f"proxy quarantined after a hard block: {pf.proxy.host}")
        if pf.exit_ip and pf.exit_ip != "direct":
            intel = ipintel.lookup(pf.exit_ip)
            why = intel.reason(self.require_residential, self.allow_countries,
                               self.region)
            self.log.write(event="ipintel", bot_id=bot_id, exit_ip=pf.exit_ip,
                           asn=intel.asn, org=intel.org, kind=intel.kind,
                           country=intel.country, usable=not why, why=why)
            if why:
                raise RuntimeError(f"proxy reputation: {why}")
        self._bound[bot_id] = raw
        return pf

    def quarantine(self, bot_id: str) -> None:
        """A hard block is the IP's problem until proven otherwise. Retrying the
        same exit inside the cooldown just spends the other bots' budget."""
        raw = self._bound.pop(bot_id, None)
        if not raw:
            return
        self._quarantined.add(raw)
        pf = self._results.get(raw)
        if pf:
            pf.ok = False
        self.log.write(event="proxy_quarantined", bot_id=bot_id,
                       proxy=pf.proxy.host if pf else raw)

    def dirty(self, bot_id: str) -> None:
        raw = self._bound.pop(bot_id, None)
        if raw and raw in self._results:
            self._results[raw].ok = False
        self.log.write(event="proxy_dirty", bot_id=bot_id, proxy=raw)

    def eligible(self) -> list[Preflight]:
        used = set(self._bound.values())
        return sorted(
            (pf for pf in self._results.values()
             if pf.eligible and pf.proxy.raw not in used
             and pf.proxy.raw not in self._quarantined),
            key=lambda pf: pf.p50_ms,
        )