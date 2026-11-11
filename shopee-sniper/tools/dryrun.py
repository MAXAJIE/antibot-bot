"""Gate 4. Timing accuracy harness. No orders placed."""
from __future__ import annotations

import argparse
import statistics

from shopee_sniper import contract
from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.timing import clock
from shopee_sniper.timing.fire import backoff_ms, fire, should_retry
from shopee_sniper.timing.rtt import RttTracker


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--fixture", default="contract/latest.json")
    ap.add_argument("--shots", type=int, default=20)
    a = ap.parse_args()

    cfg = load(a.config)
    fx = contract.load(a.fixture)
    log = JsonlLog("logs/dryrun.jsonl")

    off = clock.assert_disciplined(cfg.timing.drift_alarm_ms)
    print(f"clock offset {off:.3f}ms OK")

    host = f"shopee.{cfg.sale.region}"
    tr = RttTracker(host=host, alpha=cfg.timing.rtt_ewma_alpha,
                    samples=cfg.timing.rtt_samples)
    rtt = tr.refresh()
    if not tr.eligible(cfg.timing.rtt_min_samples):
        print("insufficient RTT samples")
        return 1
    print(f"rtt ewma {rtt / 1e6:.1f}ms, p50 {tr.p50_ms():.1f}ms")

    errs: list[float] = []
    for i in range(a.shots):
        t0 = clock.now_ns() + 1500 * 1_000_000
        res = fire("dryrun", fx, t0_ns=t0, rtt_ns=rtt,
                   ingest_ns=cfg.timing.ingest_est_ms * 1_000_000,
                   sidecar_url=cfg.sidecar_url, host=host, log=log, bot_id="dry")
        err = (res.t_send_ns - res.t_scheduled_ns) / 1e6
        errs.append(err)
        print(f"{i:02d} status={res.status} send_err={err:+.2f}ms "
              f"overshoot={res.overshoot_ms:+.2f}ms")
        if should_retry(res, 0, cfg.limits.retry_cap):
            clock.sleep_until(clock.now_ns() + backoff_ms(
                cfg.limits.retry_backoff_ms, 1) * 1_000_000)

    if not errs:
        return 1
    mean, sd = statistics.mean(errs), statistics.pstdev(errs)
    worst = max(abs(e) for e in errs)
    print(f"\nmean {mean:+.2f}ms  sd {sd:.2f}ms  worst {worst:.2f}ms")
    gate = worst <= 15.0 and abs(mean) <= 8.0
    print("GATE 4", "PASS" if gate else "FAIL")
    return 0 if gate else 1


if __name__ == "__main__":
    raise SystemExit(main())