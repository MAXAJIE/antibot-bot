"""Phase 5 proxy parsing and pre-flight.

An empty proxy, "direct" or "none" means no proxy at all: the browser goes
straight out. Correct for a single-account test, wrong for a multi-account race -
one IP per account is the point.

Sticky per account for the whole session. Rotation only on ban - mid-session
rotation invalidates the SPC_F context.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from urllib.parse import unquote, urlparse

from curl_cffi import requests as cffi

PREFLIGHT_URL = "https://api.ipify.org?format=json"
DIRECT = {"", "direct", "none", "null"}


@dataclass(frozen=True)
class Proxy:
    raw: str
    host: str
    port: int
    user: str | None = None
    password: str | None = None

    @property
    def is_direct(self) -> bool:
        return not self.host

    @property
    def url(self) -> str:
        if self.is_direct:
            return ""
        auth = f"{self.user}:{self.password}@" if self.user else ""
        return f"http://{auth}{self.host}:{self.port}"


def parse(raw: str) -> Proxy:
    if raw.strip().lower() in DIRECT:
        return Proxy(raw="", host="", port=0)
    p = urlparse(raw if "://" in raw else f"http://{raw}")
    if not p.hostname or not p.port:
        raise ValueError(f"unparseable proxy: {raw!r}")
    return Proxy(raw=raw, host=p.hostname, port=p.port,
                 user=unquote(p.username) if p.username else None,
                 password=unquote(p.password) if p.password else None)


@dataclass
class Preflight:
    proxy: Proxy
    ok: bool
    exit_ip: str | None
    p50_ms: float
    attempts: int
    checked_at: float

    @property
    def eligible(self) -> bool:
        return self.ok and self.exit_ip is not None


def preflight(proxy: Proxy, max_p50_ms: int, attempts: int = 3) -> Preflight:
    """Three tries, median latency, exit IP confirmed. Failures are discarded.

    Direct connections skip the median: there is nothing to rank, and the
    machine is either online or the run fails loudly on the first page load.
    """
    if proxy.is_direct:
        return Preflight(proxy=proxy, ok=True, exit_ip="direct", p50_ms=0.0,
                         attempts=0, checked_at=time.time())
    lat: list[float] = []
    ip: str | None = None
    for _ in range(max(1, attempts)):
        t0 = time.perf_counter()
        try:
            r = cffi.get(PREFLIGHT_URL, proxies={"https": proxy.url},
                         impersonate="chrome", timeout=12)
            lat.append((time.perf_counter() - t0) * 1000)
            ip = r.json().get("ip", ip)
        except Exception:
            continue
    p50 = sorted(lat)[len(lat) // 2] if lat else float("inf")
    return Preflight(proxy=proxy, ok=bool(lat) and p50 <= max_p50_ms,
                     exit_ip=ip, p50_ms=p50, attempts=len(lat),
                     checked_at=time.time())