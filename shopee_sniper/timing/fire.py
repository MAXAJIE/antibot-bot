"""Phase 4 T0 scheduler.

The connection must already be warm and the request already signed before this
runs. A cold handshake at T0 costs 1-2 RTT and destroys the schedule.
"""
from __future__ import annotations

import json
import time
import urllib.request
from dataclasses import dataclass

from .. import contract
from ..log import JsonlLog
from ..observe.headerhash import header_hash
from .clock import fire_instant, now_ns, sleep_until


@dataclass
class ShotResult:
    status: int
    body: str
    t_send_ns: int
    t_ack_ns: int
    t_scheduled_ns: int
    overshoot_ms: float
    rtt_ns: int

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


def _rpc(url: str, payload: dict, timeout: float = 10.0) -> dict:
    req = urllib.request.Request(
        url.rstrip("/") + "/shot",
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def fire(conn_id: str, fx: contract.Fixture, *, t0_ns: int, rtt_ns: int,
         ingest_ns: int, sidecar_url: str, host: str, log: JsonlLog,
         bot_id: str) -> ShotResult:
    target = fire_instant(t0_ns, rtt_ns, ingest_ns)
    if target <= now_ns():
        log.write(bot_id=bot_id, event="late_fire", target_ns=target,
                  now_ns=now_ns(), deficit_ms=(now_ns() - target) / 1e6)
        target = now_ns()

    overshoot = sleep_until(target)
    payload = {
        "connid": conn_id,
        "host": host,
        "method": fx.method,
        "path": fx.endpoint,
        "headers": [list(h) for h in fx.ordered_headers()],
        "body": fx.body,
    }
    res = _rpc(sidecar_url, payload)

    if res.get("error"):
        log.write(bot_id=bot_id, event="shot_error", error=res["error"],
                  overshoot_ms=overshoot)
        return ShotResult(0, res["error"], 0, 0, target, overshoot, rtt_ns)

    result = ShotResult(
        status=int(res["status"]),
        body=res.get("body", ""),
        t_send_ns=int(res["tsendns"]),
        t_ack_ns=int(res["tackns"]),
        t_scheduled_ns=target,
        overshoot_ms=overshoot,
        rtt_ns=rtt_ns,
    )
    log.write(
        bot_id=bot_id, event="shot", status=result.status,
        t_scheduled=target, t_send=result.t_send_ns, t_ack=result.t_ack_ns,
        overshoot_ms=round(overshoot, 3),
        send_error_ms=round((result.t_send_ns - target) / 1e6, 3),
        rtt_ms=round(rtt_ns / 1e6, 3),
        headers_hash=header_hash(fx.ordered_headers()),
    )
    return result


def should_retry(res: ShotResult, retries: int, cap: int) -> bool:
    """Retry only on 5xx / System busy. Never on 4xx - that burns the token."""
    if retries >= cap:
        return False
    if res.status == 0:
        return True
    if 500 <= res.status < 600:
        return True
    return "System busy" in res.body


def backoff_ms(base: int, attempt: int) -> int:
    return base * attempt + int(time.time() * 1000) % 17