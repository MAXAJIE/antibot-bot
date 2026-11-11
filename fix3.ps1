# fix5.ps1 -- 1ms timer resolution and a chunked sleep in the scheduler.

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
if (-not (Test-Path (Join-Path $root 'shopee_sniper'))) { throw "run from the repo root" }
$enc = New-Object System.Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $root ".backup/$stamp"

function W($rel, $text) {
  $p = Join-Path $root $rel
  $dir = Split-Path $p -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path $p) {
    $b = Join-Path $backup $rel
    New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
    Copy-Item $p $b -Force
  }
  [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"), $enc)
  Write-Host "  W $rel"
}

W "shopee_sniper/timing/clock.py" @'
"""Phase 4 clock discipline.

Absolute-time sleep only. Loop-sleeping on a computed delta accumulates error
and will miss a +/-15ms gate.

Windows needs two things the naive version lacked:

  timeBeginPeriod(1), because without it time.sleep(0.0385) rounds up to the
  next 15.6ms tick and returns around 47ms late. Every schedule built on that
  is already 10ms+ off before the network is involved.

  A spin margin wide enough to absorb whatever the remaining sleep overshoots
  by, and a cap on each individual sleep so a single bad tick cannot consume
  the whole margin.
"""
from __future__ import annotations

import ctypes
import re
import subprocess
import sys
import time

NS = 1_000_000_000
SPIN_NS = 4_000_000      # the last 4ms is spun, never slept
MAX_SLEEP_S = 0.002      # and no single sleep is longer than 2ms


def _raise_timer_resolution() -> None:
    """Drop the Windows scheduler tick to 1ms for this process's lifetime."""
    if sys.platform != "win32":
        return
    try:
        ctypes.windll.winmm.timeBeginPeriod(1)
    except Exception:
        pass


_raise_timer_resolution()


def now_ns() -> int:
    return time.time_ns()


def sleep_until_ns(target_ns: int) -> None:
    while True:
        rem = target_ns - now_ns()
        if rem <= 0:
            return
        if rem <= SPIN_NS:
            while now_ns() < target_ns:
                pass
            return
        time.sleep(min(max(rem - SPIN_NS, 200_000) / NS, MAX_SLEEP_S))


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
'@

Write-Host ""
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
Write-Host "  OK compiles" -ForegroundColor Green

Write-Host ""
Write-Host "measuring" -ForegroundColor Cyan
& python -c "from shopee_sniper.timing.clock import sleep_until, now_ns; o=[sleep_until(now_ns()+40_000_000) for _ in range(8)]; print('  overshoot ms:', ' '.join(f'{v:.2f}' for v in o)); print('  worst', round(max(abs(v) for v in o),2), 'ms')"
if ($LASTEXITCODE -ne 0) { throw "measure failed" }

Write-Host ""
& python -m pytest -q