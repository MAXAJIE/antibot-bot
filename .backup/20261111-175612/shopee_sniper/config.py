from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

NS = 1_000_000_000


@dataclass(frozen=True)
class Sale:
    t0: dt.datetime
    region: str
    item_id: int
    model_id: int
    quantity: int
    payment_channel_id: int
    shipping_method: str
    voucher: str | None = None

    @property
    def t0_ns(self) -> int:
        return int(self.t0.timestamp() * NS)


@dataclass(frozen=True)
class Timing:
    needle_offset_ms: int
    jitter_sigma_ms: int
    jitter_clamp_ms: tuple[int, int]
    rtt_samples: int
    rtt_min_samples: int
    rtt_ewma_alpha: float
    ingest_est_ms: int
    keepalive_ping_s: int
    drift_alarm_ms: float


@dataclass(frozen=True)
class ProxyCfg:
    max_p50_ms: int
    preflight_lead_s: int
    preflight_attempts: int


@dataclass(frozen=True)
class Limits:
    retry_cap: int
    retry_backoff_ms: int
    challenge_budget: int


@dataclass(frozen=True)
class Harvest:
    lead_ms: int
    ttl_safety: float


@dataclass(frozen=True)
class Bot:
    id: str
    account: str
    proxy: str
    profile_path: Path


@dataclass(frozen=True)
class Config:
    sale: Sale
    timing: Timing
    proxy: ProxyCfg
    limits: Limits
    harvest: Harvest
    sidecar_url: str
    bots: tuple[Bot, ...]


def _tup(v: Any) -> tuple[int, int]:
    a, b = v
    return int(a), int(b)


def load(path: str | Path) -> Config:
    raw = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    s, t, p, l, h = (raw["sale"], raw["timing"], raw["proxy"],
                     raw["limits"], raw["harvest"])
    root = Path(path).resolve().parent.parent
    sale = Sale(
        t0=dt.datetime.fromisoformat(s["t0"]),
        region=s["region"],
        item_id=int(s["item_id"]),
        model_id=int(s["model_id"]),
        quantity=int(s["quantity"]),
        payment_channel_id=int(s["payment_channel_id"]),
        shipping_method=s["shipping_method"],
        voucher=s.get("voucher"),
    )
    if sale.t0.tzinfo is None:
        raise ValueError("sale.t0 must be timezone-aware")
    return Config(
        sale=sale,
        timing=Timing(
            needle_offset_ms=int(t["needle_offset_ms"]),
            jitter_sigma_ms=int(t["jitter_sigma_ms"]),
            jitter_clamp_ms=_tup(t["jitter_clamp_ms"]),
            rtt_samples=int(t["rtt_samples"]),
            rtt_min_samples=int(t["rtt_min_samples"]),
            rtt_ewma_alpha=float(t["rtt_ewma_alpha"]),
            ingest_est_ms=int(t["ingest_est_ms"]),
            keepalive_ping_s=int(t["keepalive_ping_s"]),
            drift_alarm_ms=float(t["drift_alarm_ms"]),
        ),
        proxy=ProxyCfg(
            max_p50_ms=int(p["max_p50_ms"]),
            preflight_lead_s=int(p["preflight_lead_s"]),
            preflight_attempts=int(p["preflight_attempts"]),
        ),
        limits=Limits(
            retry_cap=int(l["retry_cap"]),
            retry_backoff_ms=int(l["retry_backoff_ms"]),
            challenge_budget=int(l["challenge_budget"]),
        ),
        harvest=Harvest(lead_ms=int(h["lead_ms"]), ttl_safety=float(h["ttl_safety"])),
        sidecar_url=str(raw["sidecar"]["url"]),
        bots=tuple(
            Bot(id=b["id"], account=b["account"], proxy=b["proxy"],
                profile_path=root / "profiles" / f"{b['id']}.json")
            for b in raw["bots"]
        ),
    )