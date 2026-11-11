"""Phase 4 RTT estimation to the Shopee edge.

TCP handshake timing only - no TLS, no HTTP. Quartile-trimmed p50 feeds an EWMA
so one GC pause does not poison the fire offset.
"""
from __future__ import annotations

import socket
import statistics
import time
from dataclasses import dataclass, field

NS = 1_000_000_000


def syn_rtt_ns(host: str, port: int = 443, timeout_s: float = 1.0) -> int:
    t0 = time.perf_counter_ns()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.settimeout(timeout_s)
    try:
        s.connect((host, port))
    finally:
        s.close()
    return time.perf_counter_ns() - t0


def trimmed_p50(samples: list[int]) -> int:
    if len(samples) < 4:
        return int(statistics.median(samples)) if samples else 0
    s = sorted(samples)
    q = max(1, len(s) // 4)
    return int(statistics.median(s[q:-q]))


@dataclass
class RttTracker:
    host: str
    alpha: float = 0.3
    samples: int = 20
    ewma_ns: float = 0.0
    count: int = 0
    _buf: list[int] = field(default_factory=list)

    def sample_once(self) -> int | None:
        try:
            v = syn_rtt_ns(self.host)
        except OSError:
            return None
        self._buf.append(v)
        self._buf = self._buf[-self.samples:]
        return v

    def refresh(self) -> int:
        for _ in range(self.samples):
            self.sample_once()
        if not self._buf:
            raise RuntimeError("no RTT samples collected")
        p50 = trimmed_p50(self._buf)
        self.ewma_ns = p50 if self.ewma_ns == 0 else (
            self.alpha * p50 + (1 - self.alpha) * self.ewma_ns)
        self.count = len(self._buf)
        return int(self.ewma_ns)

    def eligible(self, min_samples: int) -> bool:
        return self.count >= min_samples

    def p50_ms(self) -> float:
        return trimmed_p50(self._buf) / 1e6 if self._buf else float("inf")