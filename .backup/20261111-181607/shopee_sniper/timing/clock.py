"""Phase 4 clock discipline.

Absolute-time sleep only. Loop-sleeping on a computed delta accumulates error
and will miss a +/-15ms gate.
"""
from __future__ import annotations

import re
import subprocess
import time

NS = 1_000_000_000


def now_ns() -> int:
    return time.time_ns()


def sleep_until_ns(target_ns: int) -> None:
    """Portable absolute sleep.

    Windows has no clock_nanosleep; coarse-sleep to 1.5ms out, then spin.
    Roughly 0.3ms accuracy, inside the gate. Costs one core for the last 2ms.
    """
    while True:
        rem = target_ns - now_ns()
        if rem <= 0:
            return
        if rem > 2_000_000:
            time.sleep((rem - 1_500_000) / 1e9)
        else:
            while now_ns() < target_ns:
                pass
            return


def sleep_until(target_ns: int) -> float:
    sleep_until_ns(target_ns)
    return (now_ns() - target_ns) / 1e6


_TRACK = re.compile(r"^(System time|Last offset|RMS offset)\s*:\s*([-\d.]+)", re.M)


def chrony_offset_ms() -> float | None:
    try:
        out = subprocess.run(["chronyc", "tracking"], capture_output=True,
                             text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    vals = {}
    for name, num in _TRACK.findall(out):
        vals[name] = float(num)
    if "Last offset" in vals:
        return abs(vals["Last offset"]) * 1000.0
    return None


def w32time_offset_ms() -> float | None:
    """Windows fallback. w32time is much worse than chrony; expect 5-15ms."""
    try:
        out = subprocess.run(["w32tm", "/query", "/status"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"Phase Offset:\s*([\d.]+)s", out)
    return float(m.group(1)) * 1000.0 if m else None


def assert_disciplined(alarm_ms: float) -> float:
    off = chrony_offset_ms()
    if off is None:
        off = w32time_offset_ms()
    if off is None:
        raise RuntimeError("no time source reachable - cannot schedule reliably")
    if off > alarm_ms:
        raise RuntimeError(f"clock offset {off:.3f}ms exceeds {alarm_ms}ms alarm")
    return off


def fire_instant(t0_ns: int, rtt_ns: int, ingest_ns: int) -> int:
    """Target = T0 - RTT/2 - server ingest estimate."""
    return t0_ns - rtt_ns // 2 - ingest_ns