# phase6-9.ps1  --  phases 6-9, writes files directly
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$enc = New-Object System.Text.UTF8Encoding($false)
function W($rel, $text) {
  $p = Join-Path $root $rel
  $dir = Split-Path $p -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"), $enc)
  Write-Host "  $rel"
}

W "shopee_sniper/observe/__init__.py" @'
"""Phase 9: header-order forensics and metrics."""
'@

W "shopee_sniper/observe/headerhash.py" @'
"""Phase 9 header-order fingerprint.

Values rotate every shot (af-ac-enc-dat is time-derived), so the hash covers
NAMES in order only. Drift looks like a hash that moves while the body does not.
"""
from __future__ import annotations

import hashlib
from typing import Iterable

SEP = "\x1f"


def header_hash(pairs: Iterable[tuple[str, str]]) -> str:
    h = hashlib.sha256()
    for name, _ in pairs:
        h.update(name.lower().encode())
        h.update(SEP.encode())
    return h.hexdigest()[:16]


def names(pairs: Iterable[tuple[str, str]]) -> list[str]:
    return [n.lower() for n, _ in pairs]


def diff(expected: Iterable[str], actual: Iterable[str]) -> list[str]:
    """Human-readable drift. Empty list means the order still matches."""
    exp, act = list(expected), list(actual)
    if exp == act:
        return []
    out = [f"order changed at index {i}: {e!r} -> {a!r}"
           for i, (e, a) in enumerate(zip(exp, act)) if e != a]
    out += [f"missing {n!r}" for n in exp if n not in act]
    out += [f"unexpected {n!r}" for n in act if n not in exp]
    if not out:
        out.append(f"length {len(exp)} -> {len(act)}")
    return out
'@

W "shopee_sniper/observe/metrics.py" @'
"""Phase 9 Prometheus counters, derived from the JSONL journal.

Derived rather than in-process: a crashed run still exposes its last numbers and
the scraper never sits on the fire path.
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

EVENTS = ("shot", "winner", "challenged", "banned", "retry", "quorum_abort",
          "race_skip", "give_up", "late_fire", "shot_error")


def collect(paths: list[Path]) -> Counter:
    c: Counter = Counter()
    for p in paths:
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            ev = row.get("event")
            if ev in EVENTS:
                c[f"event_{ev}"] += 1
            status = row.get("status")
            try:
                code = int(status)
            except (TypeError, ValueError):
                continue
            if code == 403:
                c["status_403"] += 1
            if 200 <= code < 300:
                c["status_2xx"] += 1
    return c


def render(c: Counter, prefix: str = "sniper") -> str:
    out = []
    for key in sorted(c):
        out.append(f"# TYPE {prefix}_{key} counter")
        out.append(f"{prefix}_{key} {c[key]}")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    paths = [Path(a) for a in args] or sorted(Path("logs").glob("*.jsonl"))
    if not paths:
        print("no journals", file=sys.stderr)
        return 1
    sys.stdout.write(render(collect(paths)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "shopee_sniper/settings.py" @'
"""Optional config sections.

config.py stays strict about the required schema; the sections added in phases
6-9 are optional and defaulted here, so an existing bots.yaml keeps loading.

OTP is one IMAP mailbox with a per-bot alias rather than a mailbox per account.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass(frozen=True)
class UiCfg:
    enabled: bool = True
    host: str = "127.0.0.1"
    port: int = 8732


@dataclass(frozen=True)
class CaptchaCfg:
    enabled: bool = True
    score_min: float = 0.35
    retry_shift_px: int = 4
    settle_ms: int = 60


@dataclass(frozen=True)
class OtpCfg:
    enabled: bool = False
    host: str = ""
    port: int = 993
    user: str = ""
    password: str = ""
    sender: str = ""
    timeout_s: float = 90.0


@dataclass(frozen=True)
class Extras:
    ui: UiCfg
    captcha: CaptchaCfg
    otp: OtpCfg


def load(path: str | Path) -> Extras:
    raw = yaml.safe_load(Path(path).read_text()) or {}
    ui = raw.get("ui") or {}
    cap = raw.get("captcha") or {}
    otp = raw.get("otp") or {}
    return Extras(
        ui=UiCfg(bool(ui.get("enabled", True)), str(ui.get("host", "127.0.0.1")),
                 int(ui.get("port", 8732))),
        captcha=CaptchaCfg(bool(cap.get("enabled", True)),
                           float(cap.get("score_min", 0.35)),
                           int(cap.get("retry_shift_px", 4)),
                           int(cap.get("settle_ms", 60))),
        otp=OtpCfg(bool(otp.get("enabled", False)), str(otp.get("host", "")),
                   int(otp.get("port", 993)), str(otp.get("user", "")),
                   str(otp.get("password", "")), str(otp.get("sender", "")),
                   float(otp.get("timeout_s", 90.0))),
    )
'@

W "shopee_sniper/captcha/__init__.py" @'
"""Phase 8: challenge detection, slider solve, OTP."""
'@

W "shopee_sniper/captcha/detect.py" @'
"""Phase 8 detection.

Markers are structural, not exact strings, because Shopee renames them. When a
fixture in contract/ shows a new shape, add it here and to the test table.
"""
from __future__ import annotations

import enum


class Outcome(enum.Enum):
    OK = "OK"
    BUSY = "BUSY"
    CHALLENGE = "CHALLENGE"
    BANNED = "BANNED"
    FAIL = "FAIL"


CHALLENGE_MARKERS = ("verify/captcha", "captcha", "risk_control", "anti_bot",
                     "riskControl")
BANNED_MARKERS = ("banned", "blocked", "frozen", "account_frozen")
BUSY_MARKERS = ("System busy", "system_busy", "try again later", "too many")


def by_url(url: str) -> bool:
    return "/verify/captcha" in url


def _hit(body: str, markers: tuple[str, ...]) -> bool:
    return any(m in body for m in markers)


def classify(status: int, body: str) -> Outcome:
    if 200 <= status < 300:
        return Outcome.CHALLENGE if _hit(body, CHALLENGE_MARKERS) else Outcome.OK
    if status == 403:
        return Outcome.BANNED if _hit(body, BANNED_MARKERS) else Outcome.CHALLENGE
    if status == 429:
        return Outcome.CHALLENGE
    if 500 <= status < 600:
        return Outcome.BUSY
    if status == 0:
        return Outcome.BUSY
    if _hit(body, CHALLENGE_MARKERS):
        return Outcome.CHALLENGE
    if _hit(body, BUSY_MARKERS):
        return Outcome.BUSY
    return Outcome.FAIL
'@

W "shopee_sniper/captcha/slider.py" @'
"""Phase 8 slider solver.

Gap from Canny edges, drag as a cubic ease-out with one overshoot and a settle
correction, dispatched as real CDP mouse events. A low-confidence gap is
re-fetched rather than dragged blind.
"""
from __future__ import annotations

import asyncio
import random

import cv2
import numpy as np
from playwright.async_api import CDPSession, Page

SCORE_MIN = 0.35


class LowScore(RuntimeError):
    pass


def _decode(raw: bytes) -> np.ndarray:
    img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("undecodable image")
    return img


def _edges(img: np.ndarray) -> np.ndarray:
    return cv2.Canny(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), 100, 200)


def gap(bg: bytes, puzzle: bytes, score_min: float = SCORE_MIN) -> tuple[int, float]:
    g = _edges(_decode(bg))
    p = _edges(_decode(puzzle))
    if p.shape[0] > g.shape[0] or p.shape[1] > g.shape[1]:
        p = cv2.resize(p, (min(p.shape[1], g.shape[1]), min(p.shape[0], g.shape[0])))
    r = cv2.matchTemplate(g, p, cv2.TM_CCOEFF_NORMED)
    _, score, _, loc = cv2.minMaxLoc(r)
    if score < score_min:
        raise LowScore(f"match {score:.3f} < {score_min}")
    return loc[0], score


def curve(dist: int, rng: random.Random | None = None) -> list[tuple[float, float]]:
    r = rng or random.Random()
    steps = r.randint(28, 45)
    pts: list[tuple[float, float]] = []
    for i in range(steps):
        t = i / (steps - 1)
        pts.append((dist * (1 - (1 - t) ** 3), r.uniform(-1.0, 1.0)))
    over = r.randint(3, 6)
    pts.append((dist + over, 0.0))
    pts.append((dist + over - r.randint(2, 4), r.uniform(-0.5, 0.5)))
    pts.append((dist, 0.0))
    return pts


def delays(n: int, total_ms: int = 800, rng: random.Random | None = None) -> list[float]:
    """Per-step sleeps: 8-25ms, rescaled to land near total_ms."""
    r = rng or random.Random()
    raw = [r.uniform(8, 25) for _ in range(n)]
    k = total_ms / sum(raw)
    return [min(25.0, max(8.0, v * k)) for v in raw]


async def drag(cdp: CDPSession, x0: float, y0: float,
               pts: list[tuple[float, float]], rng: random.Random | None = None,
               total_ms: int = 800) -> None:
    await cdp.send("Input.dispatchMouseEvent", {
        "type": "mousePressed", "x": x0, "y": y0, "button": "left",
        "clickCount": 1, "buttons": 1})
    waits = delays(len(pts), total_ms, rng)
    for (dx, dy), wait in zip(pts, waits):
        await cdp.send("Input.dispatchMouseEvent", {
            "type": "mouseMoved", "x": x0 + dx, "y": y0 + dy, "button": "left",
            "buttons": 1})
        await asyncio.sleep(wait / 1000)
    await cdp.send("Input.dispatchMouseEvent", {
        "type": "mouseReleased", "x": x0 + pts[-1][0], "y": y0,
        "button": "left", "clickCount": 1, "buttons": 0})


async def solve(page: Page, cdp: CDPSession, bg_sel: str, puzzle_sel: str,
                handle_sel: str, success_sel: str = "",
                shift_px: int = 0, score_min: float = SCORE_MIN,
                rng: random.Random | None = None) -> bool:
    bg = await page.locator(bg_sel).screenshot()
    puzzle = await page.locator(puzzle_sel).screenshot()
    dist, _ = gap(bg, puzzle, score_min)
    box = await page.locator(handle_sel).bounding_box()
    if box is None:
        raise LowScore("handle not laid out")
    pts = curve(dist + shift_px, rng)
    await drag(cdp, box["x"] + box["width"] / 2, box["y"] + box["height"] / 2, pts, rng)
    if not success_sel:
        return True
    try:
        await page.wait_for_selector(success_sel, timeout=3000, state="detached")
        return True
    except Exception:
        return False
'@

W "shopee_sniper/captcha/otp.py" @'
"""Phase 8 OTP retrieval over pre-authorised IMAP.

imaplib is blocking, so the poll runs in a worker thread. Only UNSEEN mail from
the configured sender is read, newest first, and it is marked seen so a retry
cannot pick the same code.
"""
from __future__ import annotations

import asyncio
import email
import imaplib
import re
import time

from playwright.async_api import Page

from ..settings import OtpCfg

CODE_RE = re.compile(r"(?<!\d)(\d{6})(?!\d)")


class OtpTimeout(RuntimeError):
    pass


def _fetch(cfg: OtpCfg) -> str | None:
    box = imaplib.IMAP4_SSL(cfg.host, cfg.port)
    try:
        box.login(cfg.user, cfg.password)
        box.select("INBOX")
        typ, data = box.search(None, "UNSEEN", "FROM", cfg.sender)
        if typ != "OK" or not data or not data[0]:
            return None
        for num in reversed(data[0].split()[-5:]):
            typ, raw = box.fetch(num, "(RFC822)")
            if typ != "OK" or not raw or not raw[0]:
                continue
            msg = email.message_from_bytes(raw[0][1])
            body = ""
            if msg.is_multipart():
                for part in msg.walk():
                    if part.get_content_type() == "text/plain":
                        body = part.get_payload(decode=True).decode(errors="ignore")
                        break
            else:
                body = (msg.get_payload(decode=True) or b"").decode(errors="ignore")
            m = CODE_RE.search(body) or CODE_RE.search(msg.get("Subject", ""))
            if m:
                box.store(num, "+FLAGS", "\\Seen")
                return m.group(1)
        return None
    finally:
        try:
            box.logout()
        except Exception:
            pass


async def wait_code(cfg: OtpCfg, timeout_s: float | None = None) -> str:
    deadline = time.monotonic() + (timeout_s if timeout_s is not None else cfg.timeout_s)
    while time.monotonic() < deadline:
        code = await asyncio.to_thread(_fetch, cfg)
        if code:
            return code
        await asyncio.sleep(3)
    raise OtpTimeout(f"no OTP within {cfg.timeout_s:.0f}s")


async def submit(page: Page, code: str) -> None:
    """Fill every visible single-char box, then the confirm control."""
    await page.evaluate("""(code) => {
      const boxes = [...document.querySelectorAll('input[maxlength="1"]')];
      if (boxes.length === code.length) {
        boxes.forEach((b, i) => {
          b.focus();
          b.value = code[i];
          b.dispatchEvent(new Event('input', {bubbles: true}));
        });
      } else {
        const one = document.querySelector('input[type="text"], input[type="tel"]');
        if (one) {
          one.focus();
          one.value = code;
          one.dispatchEvent(new Event('input', {bubbles: true}));
        }
      }
    }""", code)
    btn = page.locator('button[class*="confirm"], button[class*="submit"]').first
    if await btn.count():
        await btn.click()
'@

W "shopee_sniper/captcha/handler.py" @'
"""Phase 8 challenge handler.

One attempt, one shifted-curve retry, then the operator gets it. Budget is per
bot per sale and lives on the Session, so a bot cannot grind forever.
"""
from __future__ import annotations

from playwright.async_api import CDPSession, Page

from ..log import JsonlLog
from ..session.state import Session
from ..settings import CaptchaCfg, OtpCfg
from ..ui.store import Store
from . import otp, slider

BG = "#captcha-bg, .captcha-bg, canvas"
PUZZLE = "#captcha-puzzle, .captcha-puzzle"
HANDLE = ".slider-handle, .captcha-slider__handle, [class*='slider-handle']"
SUCCESS = ".captcha-wrapper, .verify-captcha"


async def handle(page: Page, cdp: CDPSession, session: Session, store: Store,
                 log: JsonlLog, bot_id: str, cap: CaptchaCfg,
                 otp_cfg: OtpCfg | None = None) -> bool:
    if not cap.enabled:
        return False
    if session.challenges_used >= 3:
        log.write(bot_id=bot_id, event="challenge_budget_spent")
        store.handoff(bot_id, "budget spent")
        return False

    try:
        if await page.locator("input[maxlength='1'], input[type='tel']").count() \
                and otp_cfg and otp_cfg.enabled:
            code = await otp.wait_code(otp_cfg)
            await otp.submit(page, code)
            log.write(bot_id=bot_id, event="otp_submitted")
            return True
    except Exception as exc:
        log.write(bot_id=bot_id, event="otp_failed", error=repr(exc))

    for attempt, shift in enumerate((0, cap.retry_shift_px)):
        try:
            ok = await slider.solve(page, cdp, BG, PUZZLE, HANDLE, SUCCESS, shift_px=shift)
        except slider.LowScore as exc:
            log.write(bot_id=bot_id, event="slider_low_score", error=str(exc),
                      attempt=attempt)
            continue
        except Exception as exc:
            log.write(bot_id=bot_id, event="slider_error", error=repr(exc),
                      attempt=attempt)
            continue
        log.write(bot_id=bot_id, event="slider_result", ok=ok, attempt=attempt)
        if ok:
            return True
        await page.wait_for_timeout(cap.settle_ms)

    store.handoff(bot_id, "slider failed twice")
    return False
'@

W "shopee_sniper/ui/store.py" @'
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
'@

W "shopee_sniper/ui/console.py" @'
"""Phase 7 operator console. Stdlib only, one page, poll every 500ms.

Deliberately not a framework: this must come up on a machine where nothing but
the venv exists, and it must not compete with the fire path for a loop.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .store import Store

PAGE = """<!doctype html><meta charset=utf-8><title>sniper</title>
<style>
body{font:13px/1.4 ui-monospace,monospace;background:#111;color:#ddd;margin:0;padding:16px}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #222}
th{color:#666;font-weight:400}
#h{background:#3a0d0d;padding:8px;margin-bottom:12px;display:none}
#h.on{display:block}
button{background:#222;color:#ddd;border:1px solid #444;padding:4px 10px;cursor:pointer}
.CHALLENGED{color:#e8b} .BANNED{color:#e55} .PLACED{color:#5d5} .ARMED{color:#5ad}
</style>
<div id=h>HALTED</div>
<div><button onclick="post('halt')">HALT</button>
<button onclick="post('resume')">RESUME</button>
<button onclick="post('arm')">ARM</button></div>
<table><thead><tr><th>bot<th>state<th>rtt<th>ttl<th>offset<th>status<th>event<th>handoff</thead>
<tbody id=b></tbody></table>
<script>
const post=(a)=>fetch('/api/'+a,{method:'POST'});
async function tick(){
 const s=await (await fetch('/api/state')).json();
 document.getElementById('h').className=s.halted?'on':'';
 document.getElementById('b').innerHTML=Object.entries(s.bots).map(([k,v])=>
  `<tr><td>${k}<td class=${v.state}>${v.state}<td>${v.rtt_ms.toFixed(0)}`
  +`<td>${v.ttl_s.toFixed(1)}<td>${v.offset_ms.toFixed(0)}<td>${v.last_status||'-'}`
  +`<td>${v.last_event}<td>${v.handoff}`).join('');
}
tick(); setInterval(tick,500);
</script>"""


def make_handler(store: Store):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a) -> None:
            pass

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/":
                self._send(200, PAGE.encode(), "text/html; charset=utf-8")
            elif self.path == "/api/state":
                self._send(200, json.dumps(store.snapshot()).encode(),
                           "application/json")
            else:
                self._send(404, b"no", "text/plain")

        def do_POST(self) -> None:
            route = {
                "/api/halt": store.halt,
                "/api/resume": store.resume,
            }.get(self.path)
            if route:
                route()
                self._send(200, b"{}", "application/json")
            else:
                self._send(404, b"no", "text/plain")

    return H


def serve(store: Store, host: str = "127.0.0.1", port: int = 8732,
          background: bool = True) -> ThreadingHTTPServer:
    srv = ThreadingHTTPServer((host, port), make_handler(store))
    if background:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv
'@

W "shopee_sniper/ui/overlay.js" @'
// Phase 7 in-page HUD. Installed at document start, updated from Python.
(() => {
  const el = document.createElement("div");
  el.id = "__hud";
  el.style.cssText = [
    "position:fixed", "right:8px", "bottom:8px", "z-index:2147483647",
    "font:11px/1.35 ui-monospace,monospace", "background:#000c", "color:#ddd",
    "padding:6px 8px", "border-radius:4px", "pointer-events:none",
    "white-space:pre",
  ].join(";");
  const paint = (d) => {
    el.textContent = [
      `bot ${d.bot_id}  ${d.state}`,
      `rtt ${(d.rtt_ms || 0).toFixed(0)}ms  off ${(d.offset_ms || 0).toFixed(0)}ms`,
      `ttl ${(d.ttl_s || 0).toFixed(1)}s  last ${d.last_status || "-"}`,
      d.last_event || "",
    ].join("\n");
  };
  window.__HUD__ = paint;
  const mount = () => {
    if (!document.body) return requestAnimationFrame(mount);
    document.body.appendChild(el);
    paint(window.__HUD_INIT__ || {});
  };
  mount();
})();
'@

W "shopee_sniper/ui/inject.py" @'
"""Phase 7 overlay install.

add_init_script so the HUD survives navigation; the value is pushed from Python
rather than read from the page, so the overlay never reflects stale state.
"""
from __future__ import annotations

from pathlib import Path

from playwright.async_api import Page

OVERLAY = Path(__file__).with_name("overlay.js")


async def install(page: Page, bot_id: str) -> None:
    await page.add_init_script(
        script=OVERLAY.read_text() + f"\nwindow.__HUD_INIT__={{bot_id:'{bot_id}'}};")


async def update(page: Page, data: dict) -> None:
    try:
        await page.evaluate("d => window.__HUD__ && window.__HUD__(d)", data)
    except Exception:
        pass
'@

W "shopee_sniper/orchestrator/squad.py" @'
"""Phase 6 squad. One account, one proxy, one bot, one profile directory.

The squad owns the boring gates so the race only has to fire: proxy binding,
RTT calibration, ARMED bookkeeping, quorum and ban accounting.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..config import Bot, Config
from ..log import JsonlLog
from ..net.pool import Pool
from ..session.state import Preconditions, Session, State
from ..timing.rtt import RttTracker


@dataclass
class Squad:
    cfg: Config
    log: JsonlLog
    pool: Pool
    _sessions: dict[str, Session] = field(default_factory=dict)
    _rtt: dict[str, RttTracker] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for b in self.cfg.bots:
            self._sessions[b.id] = Session(bot_id=b.id)

    def session(self, bot_id: str) -> Session:
        return self._sessions[bot_id]

    def host(self, bot: Bot) -> str:
        return f"shopee.{self.cfg.sale.region}"

    def bind(self) -> list[str]:
        """Pre-flight every proxy, bind survivors, arm a tracker each."""
        self.pool.preflight_all([b.proxy for b in self.cfg.bots])
        live: list[str] = []
        for b in self.cfg.bots:
            try:
                pf = self.pool.bind(b.id, b.proxy)
            except (KeyError, RuntimeError) as exc:
                self.log.write(bot_id=b.id, event="proxy_ineligible", error=str(exc))
                continue
            self._rtt[b.id] = RttTracker(host=self.host(b),
                                         alpha=self.cfg.timing.rtt_ewma_alpha,
                                         samples=self.cfg.timing.rtt_samples)
            self.log.write(bot_id=b.id, event="proxy_bound",
                           p50_ms=round(pf.p50_ms, 1), exit_ip=pf.exit_ip)
            live.append(b.id)
        return live

    def calibrate(self, bot_id: str) -> int | None:
        tr = self._rtt[bot_id]
        rtt = tr.refresh()
        ok = tr.eligible(self.cfg.timing.rtt_min_samples)
        self.log.write(bot_id=bot_id, event="rtt", ewma_ms=round(rtt / 1e6, 2),
                       p50_ms=round(tr.p50_ms(), 2), eligible=ok)
        return rtt if ok else None

    def ready(self, bot_id: str) -> None:
        s = self._sessions[bot_id]
        if s.state is State.COLD:
            s.warm()
        if s.state is State.WARMING:
            s.ready()

    def arm(self, bot_id: str, pre: Preconditions) -> None:
        s = self._sessions[bot_id]
        s.pre = pre
        if s.state is State.READY:
            s.arm()

    def armed(self) -> list[Bot]:
        return [b for b in self.cfg.bots
                if self._sessions[b.id].state is State.ARMED]

    def note_challenge(self, bot_id: str) -> bool:
        """True when the quorum abort threshold is crossed."""
        challenged = sum(1 for s in self._sessions.values()
                         if s.state is State.CHALLENGED)
        return challenged / len(self._sessions) > 0.5

    def note_ban(self, bot_id: str) -> None:
        self._sessions[bot_id].ban("banned")
        self.pool.dirty(bot_id)
        self.log.write(bot_id=bot_id, event="banned")
'@

W "shopee_sniper/orchestrator/race.py" @'
"""Phase 6 race: N bots, one needle, one winner.

A shot already in flight cannot be recalled; the planbook accepts cross-account
duplicates and simply does not pay them. The halt controls one thing: no new
shot starts once a winner exists.
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from typing import Any, Callable

from .. import contract
from ..captcha.detect import Outcome, classify
from ..config import Config
from ..log import JsonlLog
from ..session.state import Session, State
from ..timing import clock
from ..timing.fire import ShotResult, backoff_ms, fire, should_retry
from .election import Election

FireFn = Callable[["Participant", int], ShotResult]


@dataclass
class Participant:
    bot_id: str
    conn_id: str
    fixture: contract.Fixture
    rtt_ns: int
    harvested_at_ms: int
    session: Session

    def ttl_remaining_s(self, ttl_safe_s: float) -> float:
        age_s = (clock.now_ns() // 1_000_000 - self.harvested_at_ms) / 1000.0
        return ttl_safe_s - age_s


@dataclass
class RaceOutcome:
    winner: str | None = None
    order_id: str | None = None
    shots: list[tuple[str, int]] = field(default_factory=list)
    aborted: bool = False
    quorum: bool = False


def order_id(body: str) -> str | None:
    try:
        doc: Any = json.loads(body)
    except (TypeError, ValueError):
        return None
    if not isinstance(doc, dict):
        return None
    for holder in (doc, doc.get("data")):
        if not isinstance(holder, dict):
            continue
        for key in ("order_id", "ordersn", "order_sn"):
            v = holder.get(key)
            if v not in (None, "", 0):
                return str(v)
    return None


class Race:
    def __init__(self, cfg: Config, log: JsonlLog, election: Election,
                 ttl_safe_s: float, sidecar_url: str, host: str, ingest_ns: int,
                 fire_fn: FireFn | None = None, hard_timeout_s: float = 25.0) -> None:
        self.cfg = cfg
        self.log = log
        self.election = election
        self.ttl_safe_s = ttl_safe_s
        self.sidecar_url = sidecar_url
        self.host = host
        self.ingest_ns = ingest_ns
        self.fire_fn = fire_fn
        self.hard_timeout_s = hard_timeout_s

    async def run(self, t0_ns: int, parts: list[Participant]) -> RaceOutcome:
        out = RaceOutcome()
        if not parts:
            return out
        offsets = self.election.offsets_ns([p.bot_id for p in parts])
        halt = asyncio.Event()
        tasks = [asyncio.create_task(self._one(p, offsets[p.bot_id], halt, out))
                 for p in parts]
        done, pending = await asyncio.wait(tasks, timeout=self.hard_timeout_s)
        if pending:
            out.aborted = True
            self.log.write(event="race_timeout", pending=len(pending))
            for t in pending:
                t.cancel()
        for t in done:
            exc = t.exception()
            if exc is not None:
                self.log.write(event="race_error", error=repr(exc))
        challenged = sum(1 for p in parts if p.session.state is State.CHALLENGED)
        out.quorum = self.election.quorum_abort(challenged, len(parts))
        if out.quorum and out.winner is None:
            out.aborted = True
            self.log.write(event="quorum_abort", challenged=challenged,
                           total=len(parts))
        return out

    async def _one(self, p: Participant, target_ns: int, halt: asyncio.Event,
                   out: RaceOutcome) -> None:
        if halt.is_set():
            self.log.write(bot_id=p.bot_id, event="race_skip", reason="halted")
            return
        if p.ttl_remaining_s(self.ttl_safe_s) <= 0:
            p.session.disarm("ttl expired before fire")
            self.log.write(bot_id=p.bot_id, event="race_skip", reason="ttl")
            return
        p.session.fire()
        while True:
            res = await asyncio.to_thread(self._fire, p, target_ns)
            out.shots.append((p.bot_id, res.status))
            if res.ok:
                oid = order_id(res.body)
                if oid:
                    won = self.election.report(p.bot_id, oid)
                    if won:
                        out.winner, out.order_id = p.bot_id, oid
                        halt.set()
                        self.log.write(bot_id=p.bot_id, event="winner", order_id=oid)
                    p.session.placed(oid)
                    return
            kind = classify(res.status, res.body)
            if kind is Outcome.CHALLENGE:
                p.session.challenge("place_order")
                self.log.write(bot_id=p.bot_id, event="challenged", status=res.status)
                return
            if kind is Outcome.BANNED:
                p.session.ban("403")
                self.log.write(bot_id=p.bot_id, event="banned")
                return
            if halt.is_set() or not should_retry(res, p.session.retries,
                                                 self.cfg.limits.retry_cap):
                p.session.fail(f"status {res.status}")
                self.log.write(bot_id=p.bot_id, event="give_up", status=res.status)
                return
            p.session.retries += 1
            delay = backoff_ms(self.cfg.limits.retry_backoff_ms, p.session.retries)
            self.log.write(bot_id=p.bot_id, event="retry", status=res.status,
                           attempt=p.session.retries, delay_ms=delay)
            await asyncio.sleep(delay / 1000)
            target_ns = clock.now_ns() + 200_000

    def _fire(self, p: Participant, target_ns: int) -> ShotResult:
        if self.fire_fn is not None:
            return self.fire_fn(p, target_ns)
        # fire() subtracts rtt/2 + ingest itself; hand back the T0 that puts the
        # actual send on target_ns.
        return fire(p.conn_id, p.fixture,
                    t0_ns=target_ns + p.rtt_ns // 2 + self.ingest_ns,
                    rtt_ns=p.rtt_ns, ingest_ns=self.ingest_ns,
                    sidecar_url=self.sidecar_url, host=self.host,
                    log=self.log, bot_id=p.bot_id)
'@

W "shopee_sniper/bot.py" @'
"""Phase 3/7 per-bot browser: the signer and the fingerprint oracle.

Headed persistent context, profile-locked, overlay installed, cart staged, then
harvest. Selectors here are the only DOM the system trusts.
"""
from __future__ import annotations

import random
from pathlib import Path

from playwright.async_api import BrowserContext, Page, Playwright

from .config import Bot, Config
from .fingerprint import profile as fp
from .log import JsonlLog
from .session import warmup
from .sign.harvest import Harvested, harvest
from .ui import inject

API = "/api/v4"


class BotRuntime:
    def __init__(self, cfg: Config, bot: Bot, log: JsonlLog) -> None:
        self.cfg = cfg
        self.bot = bot
        self.log = log
        self.prof = fp.load_or_mint(bot.profile_path, seed=bot.id)
        self.ctx: BrowserContext | None = None
        self.page: Page | None = None

    @property
    def base(self) -> str:
        return f"https://shopee.{self.cfg.sale.region}"

    async def start(self, pw: Playwright, position: tuple[int, int]) -> None:
        args = [
            f"--window-position={position[0]},{position[1]}",
            f"--window-size={self.prof.width},{self.prof.height}",
            f"--lang={self.prof.locale}",
            "--disable-blink-features=AutomationControlled",
        ]
        kwargs = fp.context_args(self.prof, self.bot.proxy)
        kwargs.pop("user_agent")
        self.ctx = await pw.chromium.launch_persistent_context(
            user_data_dir=str(Path(self.bot.profile_path).with_suffix("")),
            headless=False, args=args, user_agent=self.prof.ua, **kwargs)
        self.page = self.ctx.pages[0] if self.ctx.pages else await self.ctx.new_page()
        await inject.install(self.page, self.bot.id)
        await self.page.add_init_script(
            path=str(Path(fp.__file__).with_name("patches.js")))
        self.log.write(bot_id=self.bot.id, event="browser_start")

    async def warm(self, minutes: int) -> None:
        assert self.page
        rng = random.Random(self.bot.id)
        await warmup.warm(self.page, self.base, minutes, rng)

    async def stage_cart(self) -> None:
        """Add to cart through the page's own fetch so cookies and CSRF apply."""
        assert self.page
        sale = self.cfg.sale
        body = {"item_id": sale.item_id, "model_id": sale.model_id,
                "quantity": sale.quantity, "checkout": True, "client_source": 1}
        ok = await self.page.evaluate(
            """async ([url, body]) => {
                 const r = await fetch(url, {
                   method: 'POST', credentials: 'include',
                   headers: {'content-type': 'application/json',
                             'x-api-source': 'pc', 'x-requested-with': 'XMLHttpRequest'},
                   body: JSON.stringify(body)});
                 return r.ok;
               }""", [f"{self.base}{API}/cart/add_to_cart?bff=true", body])
        self.log.write(bot_id=self.bot.id, event="cart_staged", ok=bool(ok))
        if not ok:
            raise RuntimeError(f"cart stage failed for {self.bot.id}")

    async def open_checkout(self) -> None:
        assert self.page
        await self.page.goto(f"{self.base}/checkout", wait_until="domcontentloaded")
        await self.page.wait_for_timeout(1200)

    async def preselect(self) -> None:
        """Payment, shipping and voucher before ARMED. Tolerant by design."""
        assert self.page
        try:
            await self.page.evaluate("""(pay) => {
              const pick = (sel) => { const n = document.querySelector(sel); if (n) n.click(); };
              pick('[data-payment-channel-id="' + pay + '"]');
              pick('[class*="shipping"] [class*="option"]');
              pick('[class*="voucher"] [class*="checkbox"]');
            }""", self.cfg.sale.payment_channel_id)
        except Exception as exc:
            self.log.write(bot_id=self.bot.id, event="preselect_error", error=repr(exc))

    async def harvest(self) -> Harvested:
        assert self.page and self.ctx
        cdp = await self.ctx.new_cdp_session(self.page)
        got = await harvest(cdp, self.page, "*place_order*")
        self.log.write(bot_id=self.bot.id, event="harvest", headers=len(got.headers))
        return got

    async def close(self) -> None:
        if self.ctx:
            await self.ctx.close()
            self.log.write(bot_id=self.bot.id, event="browser_close")
'@

W "shopee_sniper/orchestrator/run.py" @'
"""Phase 6 sale runner. The only entry point that touches real orders.

Timeline: T-10min preflight and calibration, T-lead warm, T-lead harvest,
T-5s re-harvest on a stale token, T0 race, then report.
"""
from __future__ import annotations

import argparse
import asyncio
import random
import sys

from .. import contract, settings
from ..bot import BotRuntime
from ..config import load as load_cfg
from ..log import JsonlLog
from ..net.pool import Pool
from ..session.state import Preconditions
from ..timing import clock
from ..ui.store import Store
from .election import Election
from .race import Participant, Race
from .squad import Squad


async def prepare(sq: Squad, runtimes: dict[str, BotRuntime],
                  warm_min: int) -> dict[str, int]:
    """Bring bots to ARMED and return their calibrated RTT per bot."""
    live = sq.bind()
    if not live:
        return {}
    rtts: dict[str, int] = {}
    for bot_id in live:
        rtt = await asyncio.to_thread(sq.calibrate, bot_id)
        if rtt is None:
            continue
        rtts[bot_id] = rtt
        sq.ready(bot_id)
        rt = runtimes.get(bot_id)
        if rt:
            await rt.warm(warm_min)
            await rt.stage_cart()
            await rt.open_checkout()
            await rt.preselect()
        sq.arm(bot_id, Preconditions(
            cookies_present=True, spc_f_present=True, cart_staged=True,
            checkout_token_fresh=True, payment_selected=True,
            shipping_selected=True, rtt_samples=sq.cfg.timing.rtt_min_samples,
            rtt_min_samples=sq.cfg.timing.rtt_min_samples))
    return rtts


async def main_async(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--fixture", default="contract/latest.json")
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--warm-min", type=int, default=15)
    ap.add_argument("--yes", action="store_true", help="skip the confirmation")
    a = ap.parse_args(argv)

    cfg = load_cfg(a.config)
    extra = settings.load(a.config)
    log = JsonlLog("logs/sale.jsonl")
    store = Store()
    sq = Squad(cfg=cfg, log=log, pool=Pool(cfg.proxy.max_p50_ms,
                                          cfg.proxy.preflight_attempts, log))
    if extra.ui.enabled:
        from ..ui import console
        srv = console.serve(store, extra.ui.host, extra.ui.port)
        print(f"console http://{extra.ui.host}:{srv.server_port}")

    pw = None
    runtimes: dict[str, BotRuntime] = {}
    if not a.no_browser:
        from playwright.async_api import async_playwright
        pw = await async_playwright().start()
        for i, b in enumerate(cfg.bots):
            runtimes[b.id] = BotRuntime(cfg, b, log)
            await runtimes[b.id].start(pw, (40 + 640 * (i % 3), 40 + 420 * (i // 3)))

    try:
        rtts = await prepare(sq, runtimes, a.warm_min)
        if not rtts:
            print("no fire-eligible bot", file=sys.stderr)
            return 1
        print(f"armed: {sorted(rtts)}")
        if not a.yes:
            await asyncio.to_thread(input, "press enter to arm and wait for T0 ")

        fx = contract.load(a.fixture)
        ttl_safe = fx.ttl_safe_s(cfg.harvest.ttl_safety)
        parts: list[Participant] = []
        for bot_id, rtt in rtts.items():
            rt = runtimes.get(bot_id)
            got = await rt.harvest() if rt else None
            parts.append(Participant(
                bot_id=bot_id, conn_id=f"{bot_id}-{clock.now_ns() // 1_000_000_000}",
                fixture=fx, rtt_ns=rtt, harvested_at_ms=clock.now_ns() // 1_000_000,
                session=sq.session(bot_id)))
            store.upsert(bot_id, state=sq.session(bot_id).state.value,
                         rtt_ms=rtt / 1e6, ttl_s=ttl_safe)
            if got:
                log.write(bot_id=bot_id, event="harvest_ok", headers=len(got.headers))

        t0 = cfg.sale.t0_ns
        wait_ns = t0 - clock.now_ns() - cfg.harvest.lead_ms * 1_000_000
        if wait_ns > 0:
            clock.sleep_until_ns(t0 - cfg.harvest.lead_ms * 1_000_000)

        election = Election(t0_ns=t0, needle_offset_ms=cfg.timing.needle_offset_ms,
                            jitter_sigma_ms=cfg.timing.jitter_sigma_ms,
                            clamp_ms=cfg.timing.jitter_clamp_ms,
                            rng=random.Random(cfg.sale.item_id))
        race = Race(cfg, log, election, ttl_safe, cfg.sidecar_url,
                    f"shopee.{cfg.sale.region}",
                    cfg.timing.ingest_est_ms * 1_000_000)
        out = await race.run(t0, parts)
        log.write(event="race_done", winner=out.winner, order_id=out.order_id,
                  aborted=out.aborted, quorum=out.quorum)
        print(f"winner={out.winner} order={out.order_id} quorum={out.quorum}")
        return 0 if out.winner else 2
    finally:
        for rt in runtimes.values():
            await rt.close()
        if pw:
            await pw.stop()


def main() -> int:
    return asyncio.run(main_async(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/ja3.py" @'
"""Gate 3. Capture the sidecar's ClientHello and hash it.

A local sink stands in for the edge: the sidecar dials it with SNI pointed at
Shopee, we read the ClientHello, and the handshake is allowed to fail on the
certificate. Only the ClientHello matters here.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import socket
import threading
import urllib.request
from pathlib import Path


def _sink(hold: list[bytes], port_box: list[int], ready: threading.Event) -> None:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port_box.append(srv.getsockname()[1])
    ready.set()
    srv.settimeout(15)
    try:
        conn, _ = srv.accept()
        conn.settimeout(5)
        buf = b""
        while len(buf) < 5:
            buf += conn.recv(4096)
        need = 5 + int.from_bytes(buf[3:5], "big")
        while len(buf) < need:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
        hold.append(buf)
        conn.close()
    except OSError:
        pass
    finally:
        srv.close()


def _u16(b: bytes, i: int) -> tuple[int, int]:
    return int.from_bytes(b[i:i + 2], "big"), i + 2


def ja3(record: bytes) -> str:
    """JA3 over the raw ClientHello. GREASE is kept, as browsers keep it."""
    body = record[5:]
    i = 4 + 32
    sid = body[i]
    i += 1 + sid
    clen, i = _u16(body, i)
    ciphers = body[i:i + clen]
    i += clen
    comp = body[i]
    i += 1 + comp
    elen, i = _u16(body, i)
    exts = body[i:i + elen]
    curves, formats = b"", b""
    j = 0
    while j + 4 <= len(exts):
        et = int.from_bytes(exts[j:j + 2], "big")
        ln = int.from_bytes(exts[j + 2:j + 4], "big")
        data = exts[j + 4:j + 4 + ln]
        if et == 10 and len(data) > 2:
            n = int.from_bytes(data[0:2], "big")
            curves = data[2:2 + n]
        if et == 11 and len(data) > 1:
            n = data[0]
            formats = data[1:1 + n]
        j += 4 + ln
    parts = [
        str(int.from_bytes(body[0:2], "big")),
        "-".join(str(int.from_bytes(ciphers[k:k + 2], "big"))
                 for k in range(0, len(ciphers), 2)),
        "-".join(str(int.from_bytes(exts[k:k + 2], "big"))
                 for k in range(0, len(exts), 4) if k + 2 <= len(exts)),
        "-".join(str(int.from_bytes(curves[k:k + 2], "big"))
                 for k in range(0, len(curves), 2)),
        "-".join(str(b) for b in formats),
    ]
    return hashlib.md5(",".join(parts).encode()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sidecar", default="http://127.0.0.1:8731")
    ap.add_argument("--sni", default="shopee.sg")
    ap.add_argument("--record", default="")
    ap.add_argument("--expect", default="")
    a = ap.parse_args()

    hold: list[bytes] = []
    port_box: list[int] = []
    ready = threading.Event()
    th = threading.Thread(target=_sink, args=(hold, port_box, ready), daemon=True)
    th.start()
    ready.wait(5)
    host = f"127.0.0.1:{port_box[0]}"
    req = urllib.request.Request(
        a.sidecar.rstrip("/") + "/warm",
        data=json.dumps({"ConnID": "ja3", "Host": host, "SNI": a.sni}).encode(),
        headers={"content-type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception:
        pass
    th.join(10)
    if not hold:
        print("no ClientHello captured")
        return 1
    digest = ja3(hold[0])
    print(f"ja3 {digest}  bytes {len(hold[0])}")
    if a.record:
        Path(a.record).write_text(json.dumps({"sni": a.sni, "ja3": digest}, indent=2))
    if a.expect:
        want = json.loads(Path(a.expect).read_text())["ja3"]
        print("MATCH" if want == digest else f"DRIFT expected {want}")
        return 0 if want == digest else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/slider.py" @'
"""Gate 7. Solver accuracy on synthetic pairs, no network and no browser.

Synthetic pairs only prove the algorithm is not inverted. Real tiles carry
shadow and JPEG noise and score lower.
"""
from __future__ import annotations

import argparse
import random

import cv2
import numpy as np

from shopee_sniper.captcha.slider import LowScore, curve, gap

TOL = 6


def pair(x: int, rng: np.random.Generator) -> tuple[bytes, bytes]:
    bg = np.clip(245 + rng.integers(-3, 4, (160, 360, 3)), 0, 255).astype(np.uint8)
    tile = np.full((70, 70, 3), 245, np.uint8)
    cv2.rectangle(tile, (6, 6), (64, 64), (40, 40, 40), 3)
    cv2.circle(tile, (35, 35), 13, (95, 95, 95), -1)
    bg[45:115, x:x + 70] = tile
    ok1, b1 = cv2.imencode(".png", bg)
    ok2, b2 = cv2.imencode(".png", tile)
    assert ok1 and ok2
    return b1.tobytes(), b2.tobytes()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20)
    a = ap.parse_args()
    rng = np.random.default_rng(7)
    hits = 0
    for i in range(a.n):
        true_x = int(rng.integers(90, 280))
        bg, tile = pair(true_x, rng)
        try:
            found, score = gap(bg, tile)
        except LowScore as exc:
            print(f"{i:02d} low score {exc}")
            continue
        ok = abs(found - true_x) <= TOL
        hits += ok
        print(f"{i:02d} true={true_x} found={found} score={score:.3f} "
              f"{'HIT' if ok else 'MISS'}")
    rate = hits / a.n
    print(f"\n{rate:.0%} within {TOL}px")
    c = curve(180, random.Random(1))
    print(f"curve: {len(c)} points, overshoot {max(p[0] for p in c) - 180:.0f}px")
    return 0 if rate >= 0.8 else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/election.py" @'
"""Gate 6. Election and offset distribution, offline.

The fake fire returns a winner on one bot and a bare 200 elsewhere, which is
exactly the shape the race has to resolve without charging twice.
"""
from __future__ import annotations

import argparse
import asyncio
import random
import time

from shopee_sniper import contract
from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race
from shopee_sniper.session.state import Preconditions, Session
from shopee_sniper.timing.fire import ShotResult


def armed(bot_id: str) -> Session:
    s = Session(bot_id=bot_id)
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def fake(winner: str):
    def fn(p: Participant, target_ns: int) -> ShotResult:
        now = time.time_ns()
        body = '{"order_id":"A1"}' if p.bot_id == winner else '{"ok":true}'
        return ShotResult(200, body, now, now, target_ns, 0.0, 1_000_000)
    return fn


async def run(bots: int, winner: str) -> int:
    cfg = load("config/bots.example.yaml")
    log = JsonlLog("logs/election.jsonl")
    t0 = time.time_ns() + 400_000_000
    el = Election(t0_ns=t0, needle_offset_ms=cfg.timing.needle_offset_ms,
                  jitter_sigma_ms=cfg.timing.jitter_sigma_ms,
                  clamp_ms=cfg.timing.jitter_clamp_ms, rng=random.Random(3))
    ids = [f"bot{i:02d}" for i in range(1, bots + 1)]
    offs = el.offsets_ns(ids)
    spread = sorted((o - t0) // 1_000_000 for o in offs.values())
    print(f"offsets ms {spread}")
    fx = contract.Fixture(endpoint="/api/v4/checkout/place_order", method="POST",
                          header_order=("content-type",),
                          headers={"content-type": "application/json"},
                          body="{}", captured_at=int(time.time()),
                          ttl_curve=((1.0, True),))
    parts = [Participant(bot_id=i, conn_id=i, fixture=fx, rtt_ns=1_000_000,
                         harvested_at_ms=time.time_ns() // 1_000_000,
                         session=armed(i)) for i in ids]
    race = Race(cfg, log, el, 30.0, "http://127.0.0.1:8731", "shopee.sg",
                25_000_000, fire_fn=fake(winner))
    out = await race.run(t0, parts)
    placed = sum(1 for p in parts if p.session.state.value == "PLACED")
    print(f"winner={out.winner} order={out.order_id} shots={len(out.shots)} "
          f"placed={placed}")
    return 0 if out.winner == winner and placed == 1 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", type=int, default=6)
    ap.add_argument("--winner", default="bot03")
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.bots, a.winner))


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/rehearsal.py" @'
"""Gate 8. Dress rehearsal with no network: scheduler, election, no double charge.

Fake fire sleeps to the absolute target and reports the real send instant, so
send error is measured through the same code path a live shot uses.
"""
from __future__ import annotations

import argparse
import asyncio
import random
import statistics
import time

from shopee_sniper import contract
from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race
from shopee_sniper.session.state import Preconditions, Session
from shopee_sniper.timing import clock
from shopee_sniper.timing.fire import ShotResult


def armed(bot_id: str) -> Session:
    s = Session(bot_id=bot_id)
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def fake(winner: str, errs: list[float]):
    def fn(p: Participant, target_ns: int) -> ShotResult:
        clock.sleep_until_ns(target_ns)
        sent = time.time_ns()
        errs.append((sent - target_ns) / 1e6)
        body = '{"order_id":"A1"}' if p.bot_id == winner else '{"ok":true}'
        return ShotResult(200, body, sent, sent, target_ns, errs[-1], 1_000_000)
    return fn


async def run(bots: int) -> int:
    cfg = load("config/bots.example.yaml")
    log = JsonlLog("logs/rehearsal.jsonl")
    t0 = time.time_ns() + 600_000_000
    el = Election(t0_ns=t0, needle_offset_ms=cfg.timing.needle_offset_ms,
                  jitter_sigma_ms=cfg.timing.jitter_sigma_ms,
                  clamp_ms=cfg.timing.jitter_clamp_ms, rng=random.Random(11))
    ids = [f"bot{i:02d}" for i in range(1, bots + 1)]
    fx = contract.Fixture(endpoint="/api/v4/checkout/place_order", method="POST",
                          header_order=("content-type",),
                          headers={"content-type": "application/json"},
                          body="{}", captured_at=int(time.time()),
                          ttl_curve=((1.0, True),))
    parts = [Participant(bot_id=i, conn_id=i, fixture=fx, rtt_ns=1_000_000,
                         harvested_at_ms=time.time_ns() // 1_000_000,
                         session=armed(i)) for i in ids]
    errs: list[float] = []
    race = Race(cfg, log, el, 30.0, "http://127.0.0.1:8731", "shopee.sg",
                25_000_000, fire_fn=fake("bot02", errs))
    out = await race.run(t0, parts)
    placed = sum(1 for p in parts if p.session.state.value == "PLACED")
    worst = max(abs(e) for e in errs) if errs else 999
    sd = statistics.pstdev(errs) if len(errs) > 1 else 0.0
    print(f"winner={out.winner} shots={len(out.shots)} placed={placed} "
          f"worst_send_err={worst:.2f}ms sd={sd:.2f}ms")
    return 0 if out.winner and placed == 1 and worst <= 15 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", type=int, default=6)
    a = ap.parse_args()
    return asyncio.run(run(a.bots))


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/contract_diff.py" @'
"""Gate 1 upkeep. Weekly cron: diff a fresh capture against the baseline.

Exit 1 on any order or set drift so the cron mails instead of silently passing.
"""
from __future__ import annotations

import argparse

from shopee_sniper import contract
from shopee_sniper.observe import headerhash


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--live", required=True)
    a = ap.parse_args()
    base = contract.load(a.baseline)
    live = contract.load(a.live)
    problems = headerhash.diff(list(base.header_order), list(live.header_order))
    if base.body != live.body:
        problems.append("body shape changed")
    if base.endpoint != live.endpoint:
        problems.append(f"endpoint {base.endpoint} -> {live.endpoint}")
    for p in problems:
        print(f"DRIFT {p}")
    if not problems:
        print("contract stable")
        print(f"hash {headerhash.header_hash(base.ordered_headers())}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/console.py" @'
"""Phase 7 console over a finished or running journal."""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from shopee_sniper.ui import console
from shopee_sniper.ui.store import Store

KEEP = ("event", "status", "rtt_ms", "overshoot_ms", "error")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="logs/sale.jsonl")
    ap.add_argument("--port", type=int, default=8732)
    a = ap.parse_args()
    store = Store()
    p = Path(a.log)
    if p.exists():
        for line in p.read_text().splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            bot = row.get("bot_id")
            if bot:
                store.upsert(bot, **{k: v for k, v in row.items() if k in KEEP})
    srv = console.serve(store, port=a.port)
    print(f"http://127.0.0.1:{srv.server_port}")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        srv.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tests/test_headerhash.py" @'
from shopee_sniper.observe import headerhash as hh

A = [("content-type", "application/json"), ("af-ac-enc-dat", "x1")]
B = [("af-ac-enc-dat", "x1"), ("content-type", "application/json")]


def test_order_sensitive() -> None:
    assert hh.header_hash(A) != hh.header_hash(B)


def test_value_insensitive() -> None:
    rotated = [("content-type", "application/json"), ("af-ac-enc-dat", "zz9")]
    assert hh.header_hash(A) == hh.header_hash(rotated)


def test_diff_names_drift() -> None:
    out = hh.diff(hh.names(A), hh.names(B))
    assert any("order changed" in line for line in out)


def test_diff_clean() -> None:
    assert hh.diff(hh.names(A), hh.names(A)) == []
'@

W "tests/test_metrics.py" @'
import json
from pathlib import Path

from shopee_sniper.observe.metrics import collect, render


def _journal(tmp_path: Path) -> Path:
    p = tmp_path / "j.jsonl"
    rows = [
        {"event": "shot", "status": 200},
        {"event": "shot", "status": 403},
        {"event": "challenged", "status": 403},
        {"event": "winner", "status": 200},
        {"note": "no event"},
    ]
    p.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
    return p


def test_counts(tmp_path: Path) -> None:
    c = collect([_journal(tmp_path)])
    assert c["status_2xx"] == 2
    assert c["status_403"] == 2
    assert c["event_shot"] == 2
    assert c["event_winner"] == 1


def test_render_shape(tmp_path: Path) -> None:
    out = render(collect([_journal(tmp_path)]))
    assert "# TYPE sniper_status_2xx counter" in out
'@

W "tests/test_detect.py" @'
from shopee_sniper.captcha.detect import Outcome, by_url, classify


def test_ok() -> None:
    assert classify(200, '{"order_id":1}') is Outcome.OK


def test_captcha_url() -> None:
    assert by_url("https://shopee.sg/verify/captcha/get?x=1")


def test_challenge_in_body() -> None:
    assert classify(200, '{"error":"risk_control"}') is Outcome.CHALLENGE


def test_banned() -> None:
    assert classify(403, '{"msg":"account frozen"}') is Outcome.BANNED


def test_403_without_marker_is_challenge() -> None:
    assert classify(403, "forbidden") is Outcome.CHALLENGE


def test_busy_and_fail() -> None:
    assert classify(503, "System busy") is Outcome.BUSY
    assert classify(400, "bad") is Outcome.FAIL
'@

W "tests/test_slider.py" @'
import random

import cv2
import numpy as np
import pytest

from shopee_sniper.captcha.slider import LowScore, curve, delays, gap


def _pair(x: int) -> tuple[bytes, bytes]:
    rng = np.random.default_rng(0)
    bg = np.clip(245 + rng.integers(-3, 4, (160, 360, 3)), 0, 255).astype(np.uint8)
    tile = np.full((70, 70, 3), 245, np.uint8)
    cv2.rectangle(tile, (6, 6), (64, 64), (40, 40, 40), 3)
    cv2.circle(tile, (35, 35), 13, (95, 95, 95), -1)
    bg[45:115, x:x + 70] = tile
    return cv2.imencode(".png", bg)[1].tobytes(), cv2.imencode(".png", tile)[1].tobytes()


def test_gap_finds_tile() -> None:
    bg, tile = _pair(180)
    found, score = gap(bg, tile)
    assert abs(found - 180) <= 10
    assert score > 0.35


def test_low_score_raises() -> None:
    bg, _ = _pair(180)
    flat = np.full((60, 60, 3), 255, np.uint8)
    with pytest.raises(LowScore):
        gap(bg, cv2.imencode(".png", flat)[1].tobytes(), score_min=0.9)


def test_curve_shape() -> None:
    pts = curve(200, random.Random(5))
    xs = [p[0] for p in pts]
    assert 30 <= len(pts) <= 48
    assert xs[-1] == 200
    assert max(xs) > 200
    assert all(b >= a - 6 for a, b in zip(xs, xs[1:]))


def test_delays_bounds() -> None:
    d = delays(30, 800, random.Random(1))
    assert all(8 <= v <= 25 for v in d)
'@

W "tests/test_store.py" @'
from shopee_sniper.ui.store import Store


def test_snapshot_is_a_copy() -> None:
    s = Store()
    s.upsert("b1", state="ARMED")
    snap = s.snapshot()
    snap["bots"]["b1"]["state"] = "BANNED"
    assert s.snapshot()["bots"]["b1"]["state"] == "ARMED"


def test_unknown_field_ignored() -> None:
    s = Store()
    s.upsert("b1", nope=1)
    assert "nope" not in s.snapshot()["bots"]["b1"]


def test_halt_flag() -> None:
    s = Store()
    assert not s.halted()
    s.halt()
    assert s.halted()
    s.resume()
    assert not s.halted()


def test_handoff_tracked() -> None:
    s = Store()
    s.handoff("b1", "slider failed")
    assert s.handoffs() == ["b1"]
'@

W "tests/test_race.py" @'
import asyncio
import time

from shopee_sniper import contract
from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race, order_id
from shopee_sniper.session.state import Preconditions, Session
from shopee_sniper.timing.fire import ShotResult

CFG = load("config/bots.example.yaml")
FX = contract.Fixture(endpoint="/x", method="POST", header_order=("a",),
                      headers={"a": "b"}, body="{}", captured_at=0,
                      ttl_curve=((1.0, True),))


def armed(bot_id: str) -> Session:
    s = Session(bot_id=bot_id)
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def part(bot_id: str, age_ms: int = 0) -> Participant:
    return Participant(bot_id=bot_id, conn_id=bot_id, fixture=FX, rtt_ns=1_000_000,
                       harvested_at_ms=time.time_ns() // 1_000_000 - age_ms,
                       session=armed(bot_id))


def test_order_id_extraction() -> None:
    assert order_id('{"data":{"order_id":42}}') == "42"
    assert order_id('{"ok":true}') is None
    assert order_id("garbage") is None


def test_expired_ttl_skips() -> None:
    el = Election(t0_ns=0, needle_offset_ms=0, jitter_sigma_ms=1, clamp_ms=(0, 0))
    race = Race(CFG, JsonlLog("logs/t.jsonl"), el, 1.0, "http://x", "h", 0,
                fire_fn=lambda p, t: ShotResult(200, '{"order_id":1}', 1, 1, t, 0.0, 1))
    p = part("bot01", age_ms=5000)
    out = asyncio.run(race.run(time.time_ns(), [p]))
    assert out.winner is None
    assert p.session.state.value == "READY"
'@

# --- rewrites of existing files (full content, no context matching) ---

W "shopee_sniper/timing/fire.py" @'
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
'@

W "shopee_sniper/orchestrator/election.py" @'
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
'@

W ".gitignore" @'
.venv/
bin/
logs/
profiles/*.json
contract/cap_*.json
config/bots.yaml
__pycache__/
*.pyc
contract/ja3_*.json
state/
'@

W "pyproject.toml" @'
[project]
name = "shopee-sniper"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
  "playwright>=1.44",
  "curl_cffi>=0.6",
  "pyyaml>=6.0",
  "numpy>=1.26",
  "opencv-python>=4.9",
  "structlog>=24.1",
  "mitmproxy>=10.2",
]

[project.optional-dependencies]
dev = ["pytest>=8.0", "scapy>=2.5"]

[tool.setuptools]
packages = ["shopee_sniper", "shopee_sniper.fingerprint", "shopee_sniper.sign",
            "shopee_sniper.session", "shopee_sniper.timing", "shopee_sniper.net",
            "shopee_sniper.orchestrator", "shopee_sniper.ui",
            "shopee_sniper.captcha", "shopee_sniper.observe"]
'@

W "Makefile" @'
.PHONY: setup build test clean
setup:
	python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"
build:
	cd sidecar && go build -o ../bin/sidecar .
test:
	python -m pytest -q
clean:
	rm -rf bin logs .venv

.PHONY: gates console rehearsal
gates:
	python -m tools.ja3 --record contract/ja3.json
	python -m tools.slider --n 20
	python -m tools.election --bots 6 --dry
	python -m tools.rehearsal --bots 6

console:
	python -m tools.console --log logs/sale.jsonl

rehearsal:
	python -m tools.rehearsal --bots 6
'@

W "PHASES.md" @'
# Phases 6-9

Implemented: race, squad, runner, browser runtime, console, overlay, slider,
OTP, detection, header-order forensics, metrics, and the missing gates.

## What is verified offline

    python -m pytest -q
    python -m tools.slider --n 20
    python -m tools.election --bots 6
    python -m tools.rehearsal --bots 6
    python -m shopee_sniper.observe.metrics logs/*.jsonl

## What is not

- `bot.py` cart body, payment/shipping selectors, and the `detect.py` marker
  table are shaped guesses. They need a Phase 0 capture to become facts.
- `tools/ja3.py` compares against a recording, not a baked constant. Record
  once per Chrome major: `python -m tools.ja3 --record contract/ja3_131.json`.
- `tools/slider.py` scores synthetic tiles. Real tiles are noisier.
- `run.py` places real orders. `--no-browser` only skips the browser.

## Gate order still applies

Gate 1 (contract) must be green before any live run. A stale fixture is a
guaranteed 403 or a burned token, not a slow order.

## Known conflict in the spec

The planbook sets the needle at T0-15ms and clamps everyone else to
[-40ms, +180ms]. That lets part of the pack fire before the needle. Kept as
specified; if the needle must lead, clamp to [-15, 180].

## Failure triage

`logs/*.jsonl` carries `event`, `status`, `ttl_remaining`, `overshoot_ms`,
`send_error_ms` and `headers_hash`. Status first: 403 is fingerprint or IP,
never timing. Then ttl. Then hash diff. Only then the account.

## Budgets

3 challenges per bot per sale, 2 retries per shot, one proxy per bot for the
whole session. Quorum abort above 50% challenged.
'@

Write-Host ""
Write-Host "done. now run:" -ForegroundColor Green
Write-Host "  python -m pytest -q"
Write-Host "  python -m tools.slider --n 20"
Write-Host "  python -m tools.rehearsal --bots 6"
Write-Host ""
Write-Host "then commit:" -ForegroundColor Green
Write-Host "  git add -A; git commit -m 'phases 6-9'"