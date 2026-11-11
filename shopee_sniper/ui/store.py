"""Phase 7 live state. Console and overlay read here, never from the journal.

Journal is append-only truth for after the sale; this is the mutable view the
operator actually watches. One lock, short critical sections, no callbacks.
"""
from __future__ import annotations

import threading
import time
from dataclasses import asdict, dataclass, field


@dataclass
class View:
    state: str = "COLD"
    rtt_ms: float = 0.0
    ttl_s: float = 0.0
    offset_ms: float = 0.0
    last_status: int = 0
    last_event: str = ""
    handoff: str = ""
    ts: float = field(default_factory=time.time)


class Store:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._bots: dict[str, View] = {}
        self._halt = threading.Event()

    def upsert(self, bot_id: str, **fields) -> None:
        with self._lock:
            v = self._bots.setdefault(bot_id, View())
            for k, val in fields.items():
                if hasattr(v, k):
                    setattr(v, k, val)
            v.ts = time.time()

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "halted": self._halt.is_set(),
                "ts": time.time(),
                "bots": {k: asdict(v) for k, v in sorted(self._bots.items())},
            }

    def halt(self) -> None:
        self._halt.set()

    def resume(self) -> None:
        self._halt.clear()

    def halted(self) -> bool:
        return self._halt.is_set()

    def handoff(self, bot_id: str, reason: str) -> None:
        self.upsert(bot_id, handoff=reason)

    def handoffs(self) -> list[str]:
        with self._lock:
            return [k for k, v in self._bots.items() if v.handoff]

    def all_armed(self) -> bool:
        with self._lock:
            return bool(self._bots) and all(v.state == "ARMED"
                                            for v in self._bots.values())