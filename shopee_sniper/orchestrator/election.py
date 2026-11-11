"""Phase 6 election. One needle, the rest jittered, exactly one winner."""
from __future__ import annotations

import asyncio
import random
from dataclasses import dataclass

NS = 1_000_000_000


@dataclass
class Election:
    t0_ns: int
    needle_offset_ms: int
    jitter_sigma_ms: int
    clamp_ms: tuple[int, int]
    rng: random.Random | None = None
    winner: str | None = None
    halted: bool = False

    def offsets_ns(self, bot_ids: list[str]) -> dict[str, int]:
        """One needle at T0+offset, rest Gaussian and clamped."""
        out = {}
        needle = min(bot_ids)
        for b in bot_ids:
            if b == needle:
                off = self.needle_offset_ms
            else:
                rng = self.rng or random
                off = int(rng.gauss(0, self.jitter_sigma_ms))
                lo, hi = self.clamp_ms
                off = max(lo, min(hi, off))
            out[b] = self.t0_ns + off * 1_000_000
        return out

    def report(self, bot_id: str, order_id: str) -> bool:
        """First 2xx with an order_id wins; returns True if this call won."""
        if self.winner is not None:
            return False
        self.winner = bot_id
        self.halted = True
        return True

    def quorum_abort(self, challenged: int, total: int) -> bool:
        return total > 0 and challenged / total > 0.5


async def wait_halt(ev: asyncio.Event) -> None:
    await ev.wait()