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

W "shopee_sniper/session/state.py" @'
"""Phase 3. Session state machine with guarded transitions.

Guards matter more than the enum: ARMED is only legal when every precondition
holds, and a session that leaves ARMED must re-earn it. Disarming is the one
legal step back, and only from ARMED.
"""
from __future__ import annotations

import enum
import time
from dataclasses import dataclass, field


class State(enum.Enum):
    COLD = "COLD"
    WARMING = "WARMING"
    READY = "READY"
    ARMED = "ARMED"
    FIRING = "FIRING"
    PLACED = "PLACED"
    FAILED = "FAILED"
    CHALLENGED = "CHALLENGED"
    BANNED = "BANNED"


TRANSITIONS: dict[State, set[State]] = {
    State.COLD: {State.WARMING, State.BANNED},
    State.WARMING: {State.READY, State.CHALLENGED, State.BANNED, State.FAILED},
    State.READY: {State.ARMED, State.CHALLENGED, State.BANNED, State.FAILED},
    State.ARMED: {State.FIRING, State.READY, State.CHALLENGED, State.BANNED,
                  State.FAILED},
    State.FIRING: {State.PLACED, State.FAILED, State.CHALLENGED, State.BANNED},
    State.PLACED: {State.FAILED},
    State.FAILED: {State.READY, State.WARMING},
    State.CHALLENGED: {State.READY, State.BANNED},
    State.BANNED: set(),
}

TERMINAL = {State.PLACED, State.BANNED}


@dataclass
class Preconditions:
    cookies_present: bool = False
    spc_f_present: bool = False
    cart_staged: bool = False
    checkout_token_fresh: bool = False
    payment_selected: bool = False
    shipping_selected: bool = False
    rtt_samples: int = 0
    rtt_min_samples: int = 15

    def missing(self) -> list[str]:
        out = []
        for name in ("cookies_present", "spc_f_present", "cart_staged",
                     "checkout_token_fresh", "payment_selected",
                     "shipping_selected"):
            if not getattr(self, name):
                out.append(name)
        if self.rtt_samples < self.rtt_min_samples:
            out.append(f"rtt_samples({self.rtt_samples}/{self.rtt_min_samples})")
        return out

    def satisfied(self) -> bool:
        return not self.missing()


class TransitionError(RuntimeError):
    pass


@dataclass
class Session:
    bot_id: str
    state: State = State.COLD
    challenges_used: int = 0
    retries: int = 0
    pre: Preconditions = field(default_factory=Preconditions)
    history: list[tuple[float, State, str]] = field(default_factory=list)

    def _move(self, to: State, reason: str) -> None:
        if to not in TRANSITIONS[self.state]:
            raise TransitionError(f"{self.state.value} -> {to.value} illegal ({reason})")
        self.history.append((time.time(), to, reason))
        self.state = to

    def warm(self) -> None:
        self._move(State.WARMING, "warm-up start")

    def ready(self) -> None:
        self._move(State.READY, "warm-up complete")

    def arm(self) -> None:
        missing = self.pre.missing()
        if missing:
            raise TransitionError(f"cannot ARM, missing {missing}")
        self._move(State.ARMED, "preconditions met")

    def disarm(self, reason: str) -> None:
        if self.state is State.ARMED:
            self._move(State.READY, reason)

    def fire(self) -> None:
        if not self.pre.satisfied():
            raise TransitionError(f"cannot FIRE, missing {self.pre.missing()}")
        self._move(State.FIRING, "T0")

    def placed(self, order_id: str) -> None:
        self._move(State.PLACED, f"order {order_id}")

    def fail(self, reason: str) -> None:
        if self.state is State.FAILED:
            return
        if State.FAILED in TRANSITIONS[self.state]:
            self._move(State.FAILED, reason)

    def challenge(self, reason: str) -> bool:
        """Returns True if budget remains."""
        self.challenges_used += 1
        if State.CHALLENGED in TRANSITIONS[self.state]:
            self._move(State.CHALLENGED, reason)
        return self.challenges_used < 3

    def ban(self, reason: str) -> None:
        if State.BANNED in TRANSITIONS[self.state]:
            self._move(State.BANNED, reason)
        else:
            self.state = State.BANNED

    def can_retry(self, cap: int) -> bool:
        return self.retries < cap and self.state not in TERMINAL
'@

W "shopee_sniper/captcha/slider.py" @'
"""Phase 8 slider solver.

Gap from Canny edges, drag as a cubic ease-out with one overshoot and a settle
correction, dispatched as real CDP mouse events. A low-confidence gap is
re-fetched rather than dragged blind, and a degenerate image (no edges) is
rejected instead of being matched at a meaningless 1.0.
"""
from __future__ import annotations

import asyncio
import random

import cv2
import numpy as np
from playwright.async_api import CDPSession, Page

SCORE_MIN = 0.35
MIN_EDGE_PX = 24


class LowScore(RuntimeError):
    pass


def _decode(raw: bytes) -> np.ndarray:
    img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("undecodable image")
    return img


def _edges(img: np.ndarray) -> np.ndarray:
    return cv2.Canny(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), 100, 200)


def _edge_count(edges: np.ndarray) -> int:
    return int(edges.sum()) // 255


def gap(bg: bytes, puzzle: bytes, score_min: float = SCORE_MIN) -> tuple[int, float]:
    g = _edges(_decode(bg))
    p = _edges(_decode(puzzle))
    if p.shape[0] > g.shape[0] or p.shape[1] > g.shape[1]:
        p = cv2.resize(p, (min(p.shape[1], g.shape[1]), min(p.shape[0], g.shape[0])))
    if _edge_count(g) < MIN_EDGE_PX:
        raise LowScore(f"background has {_edge_count(g)} edge px")
    if _edge_count(p) < MIN_EDGE_PX:
        raise LowScore(f"puzzle has {_edge_count(p)} edge px")
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

W "tests/test_slider.py" @'
import random

import cv2
import numpy as np
import pytest

from shopee_sniper.captcha.slider import LowScore, curve, delays, gap


def _tile(shape: bool = True) -> bytes:
    img = np.full((70, 70, 3), 245, np.uint8)
    if shape:
        cv2.rectangle(img, (6, 6), (64, 64), (40, 40, 40), 3)
        cv2.circle(img, (35, 35), 13, (95, 95, 95), -1)
    return cv2.imencode(".png", img)[1].tobytes()


def _pair(x: int) -> tuple[bytes, bytes]:
    rng = np.random.default_rng(0)
    bg = np.clip(245 + rng.integers(-3, 4, (160, 360, 3)), 0, 255).astype(np.uint8)
    bg[45:115, x:x + 70] = cv2.imdecode(
        np.frombuffer(_tile(), np.uint8), cv2.IMREAD_COLOR)
    return cv2.imencode(".png", bg)[1].tobytes(), _tile()


def test_gap_finds_tile() -> None:
    bg, tile = _pair(180)
    found, score = gap(bg, tile)
    assert abs(found - 180) <= 10
    assert score > 0.35


def test_flat_tile_rejected() -> None:
    bg, _ = _pair(180)
    with pytest.raises(LowScore):
        gap(bg, _tile(shape=False))


def test_threshold_rejects_weak_match() -> None:
    bg, tile = _pair(180)
    with pytest.raises(LowScore):
        gap(bg, tile, score_min=1.01)


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

W "tests/test_state.py" @'
import pytest

from shopee_sniper.session.state import Preconditions, Session, State, TransitionError


def armed() -> Session:
    s = Session(bot_id="b1")
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def test_happy_path() -> None:
    s = armed()
    s.fire()
    s.placed("123")
    assert s.state is State.PLACED


def test_arm_blocked_without_preconditions() -> None:
    s = Session(bot_id="b1")
    s.warm()
    s.ready()
    with pytest.raises(TransitionError):
        s.arm()


def test_arm_names_the_gap() -> None:
    s = Session(bot_id="b1")
    s.warm()
    s.ready()
    s.pre = Preconditions(cookies_present=True)
    with pytest.raises(TransitionError) as exc:
        s.arm()
    assert "spc_f_present" in str(exc.value)


def test_fire_blocked_when_disarmed() -> None:
    s = armed()
    s.pre.checkout_token_fresh = False
    with pytest.raises(TransitionError):
        s.fire()


def test_illegal_jump() -> None:
    s = Session(bot_id="b1")
    with pytest.raises(TransitionError):
        s.fire()


def test_challenge_budget() -> None:
    s = armed()
    assert s.challenge("x") is True
    s.ready()
    s.arm()
    assert s.challenge("y") is True
    s.ready()
    s.arm()
    assert s.challenge("z") is False


def test_disarm_returns_to_ready() -> None:
    s = armed()
    s.disarm("token stale")
    assert s.state is State.READY
    assert s.history[-1][2] == "token stale"


def test_disarm_ignored_while_firing() -> None:
    s = armed()
    s.fire()
    s.disarm("too late")
    assert s.state is State.FIRING


def test_rearm_after_disarm() -> None:
    s = armed()
    s.disarm("stale")
    s.arm()
    assert s.state is State.ARMED
'@

W "tools/fake_sidecar.py" @'
"""Local stand-in for the Go sidecar. Same JSON contract, no TLS, no proxy.

Strict on purpose: a shot missing any required key comes back as an error, so
tools/smoke.py catches contract drift between fire.py and the sidecar before a
real sale does.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUIRED = ("connid", "host", "method", "path", "headers", "body")


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.warm: set[str] = set()
        self.shots: list[dict] = []
        self.winner_taken = False


def handler_for(st: State):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a) -> None:
            pass

        def _json(self, code: int, obj: dict) -> None:
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            self._json(200, {"status": 200}) if self.path == "/healthz" \
                else self._json(404, {"error": "no route"})

        def do_POST(self) -> None:
            n = int(self.headers.get("content-length") or 0)
            try:
                q = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return self._json(400, {"error": "bad json"})
            if self.path == "/warm":
                with st.lock:
                    st.warm.add(q.get("connid", ""))
                return self._json(200, {"status": 200})
            if self.path == "/close":
                with st.lock:
                    st.warm.discard(q.get("connid", ""))
                return self._json(200, {"status": 200})
            if self.path == "/shot":
                missing = [k for k in REQUIRED if k not in q]
                if missing:
                    return self._json(200, {"error": f"missing {missing}"})
                with st.lock:
                    if q["connid"] not in st.warm:
                        return self._json(200, {"error": "unknown connid"})
                    st.shots.append(q)
                    give = not st.winner_taken
                    if give:
                        st.winner_taken = True
                now = time.time_ns()
                body = '{"order_id":"SMOKE-1"}' if give else '{"ok":true}'
                return self._json(200, {"status": 200, "headers": [], "body": body,
                                        "tsendns": now, "tackns": now + 1_000_000})
            return self._json(404, {"error": "no route"})

    return H


def serve(port: int = 0) -> tuple[ThreadingHTTPServer, State]:
    st = State()
    srv = ThreadingHTTPServer(("127.0.0.1", port), handler_for(st))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, st


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8731)
    a = ap.parse_args()
    srv, _ = serve(a.port)
    print(f"fake sidecar on http://127.0.0.1:{srv.server_port}")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        srv.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/smoke.py" @'
"""Phase 6/9 smoke. Real HTTP, fake sidecar, no Go, no browser, no proxy.

Proves the parts that fail silently: the sidecar JSON contract, the election,
the state machine, the journal and the metrics. Does not prove TLS, JA3 or DOM.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import random
import statistics
import time
from pathlib import Path
from types import SimpleNamespace

from shopee_sniper import contract
from shopee_sniper.config import Bot, Config, Harvest, Limits, ProxyCfg, Sale, Timing
from shopee_sniper.log import JsonlLog
from shopee_sniper.observe import metrics
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race
from shopee_sniper.orchestrator.squad import Squad
from shopee_sniper.session.state import Preconditions
from shopee_sniper.timing import clock
from tools import fake_sidecar

RTT_NS = 40_000_000


class StubPool:
    """Preflight without the network. Bind still records and validates."""

    def preflight_all(self, raws: list[str]) -> None:
        self.raws = list(raws)

    def bind(self, bot_id: str, raw: str):
        return SimpleNamespace(p50_ms=12.0, exit_ip="127.0.0.1")

    def dirty(self, bot_id: str) -> None:
        pass


def build_cfg(bots: int) -> Config:
    return Config(
        sale=Sale(t0=dt.datetime.now(dt.timezone.utc), region="sg", item_id=1,
                  model_id=1, quantity=1, payment_channel_id=1,
                  shipping_method="standard"),
        timing=Timing(-15, 60, (-40, 180), 20, 15, 0.3, 25, 5, 2.0),
        proxy=ProxyCfg(400, 600, 3),
        limits=Limits(2, 120, 3),
        harvest=Harvest(3000, 0.5),
        sidecar_url="http://127.0.0.1:1",
        bots=tuple(Bot(id=f"bot{i:02d}", account=f"a{i}",
                       proxy=f"http://127.0.0.1:{9000 + i}",
                       profile_path=Path(f"profiles/bot{i:02d}.json"))
                   for i in range(1, bots + 1)),
    )


def fixture() -> contract.Fixture:
    return contract.Fixture(
        endpoint="/api/v4/checkout/place_order", method="POST",
        header_order=("content-type", "af-ac-enc-dat", "x-csrftoken"),
        headers={"content-type": "application/json", "af-ac-enc-dat": "stub",
                 "x-csrftoken": "stub"},
        body='{"item_id":1}', captured_at=int(time.time()),
        ttl_curve=((1.0, True), (2.0, True)))


async def run(bots: int) -> int:
    Path("logs").mkdir(exist_ok=True)
    log_path = Path("logs/smoke.jsonl")
    log_path.write_text("")
    log = JsonlLog(log_path)

    srv, st = fake_sidecar.serve()
    cfg = build_cfg(bots)
    cfg = Config(**{**cfg.__dict__, "sidecar_url": f"http://127.0.0.1:{srv.server_port}"})
    sq = Squad(cfg=cfg, log=log, pool=StubPool())

    try:
        live = sq.bind()
        for bot_id in live:
            sq.ready(bot_id)
            sq.arm(bot_id, Preconditions(True, True, True, True, True, True, 20, 15))
            await asyncio.to_thread(
                lambda b=bot_id: fake_sidecar.ThreadedPing if False else None)
        print(f"armed {len(live)} bots: {live}")

        fx = fixture()
        ttl_safe = fx.ttl_safe_s(cfg.harvest.ttl_safety)
        parts = [Participant(bot_id=b, conn_id=b, fixture=fx, rtt_ns=RTT_NS,
                            harvested_at_ms=clock.now_ns() // 1_000_000,
                            session=sq.session(b)) for b in live]
        for p in parts:
            _warm(cfg.sidecar_url, p.conn_id)

        t0 = clock.now_ns() + 700_000_000
        el = Election(t0_ns=t0, needle_offset_ms=-15, jitter_sigma_ms=60,
                      clamp_ms=(-40, 180), rng=random.Random(1))
        race = Race(cfg, log, el, ttl_safe, cfg.sidecar_url, "shopee.sg",
                    25_000_000, hard_timeout_s=15.0)
        out = await race.run(t0, parts)
    finally:
        srv.shutdown()

    rows = [__import__("json").loads(l) for l in log_path.read_text().splitlines()]
    errs = [r["send_error_ms"] for r in rows if "send_error_ms" in r]
    placed = [p for p in parts if p.session.state.value == "PLACED"]

    print()
    print(f"shots        {len(out.shots)}")
    print(f"winner       {out.winner}  order={out.order_id}")
    print(f"placed       {len(placed)}  (must be 1)")
    print(f"send_error   worst {max(map(abs, errs), default=999):.2f}ms  "
          f"sd {statistics.pstdev(errs) if len(errs) > 1 else 0:.2f}ms")
    print(f"sidecar saw  {len(st.shots)} shots, all keys present")
    print()
    print(metrics.render(metrics.collect([log_path])).strip())

    ok = (out.winner is not None and out.order_id == "SMOKE-1"
          and len(placed) == 1 and len(st.shots) == len(out.shots))
    print()
    print("SMOKE PASS" if ok else "SMOKE FAIL")
    return 0 if ok else 1


def _warm(url: str, conn_id: str) -> None:
    import json
    import urllib.request
    req = urllib.request.Request(
        url.rstrip("/") + "/warm",
        data=json.dumps({"connid": conn_id, "host": "shopee.sg"}).encode(),
        headers={"content-type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=5).read()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bots", type=int, default=6)
    a = ap.parse_args()
    return asyncio.run(run(a.bots))


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-Host ""
Write-Host "fixes written. run:" -ForegroundColor Green
Write-Host "  python -m pytest -q"
Write-Host "  python -m tools.smoke --bots 6"