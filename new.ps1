# bypass3.ps1 -- repair the gate, the classifier and the settings file.

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

Write-Host ""
Write-Host "1/4 settings.py (full rewrite, adds the bypass section)" -ForegroundColor Cyan

W "shopee_sniper/settings.py" @'
"""Optional config sections.

config.py stays strict about the required schema; everything added in phases 6-9
is optional and defaulted here, so an existing bots.yaml keeps loading.

Every section has from_dict() so a future frontend can POST a dict instead of
writing YAML.
"""
from __future__ import annotations

import enum
from dataclasses import dataclass, field
from pathlib import Path

import yaml


class Mode(enum.Enum):
    """test walks to place_order and aborts. real places."""

    TEST = "test"
    REAL = "real"


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
class BypassCfg:
    """Mirror of config.BypassCfg for tools that load settings alone."""

    channel: str = "chrome"
    executable: str = ""
    native_ua: bool = True
    fp_strict: bool = True


@dataclass(frozen=True)
class DriveCfg:
    """What to buy and how to recognise it.

    variant is the spec text joined with '|', e.g. "Size: M|Black".
    address_label and payment_method are matched as visible text.
    """

    mode: Mode = Mode.TEST
    product_url: str = ""
    variant: str = ""
    quantity: int = 1
    expected_price: float = 0.0
    price_tolerance: float = 0.02
    payment_method: str = ""
    address_label: str = ""
    selectors_path: str = ""
    keep_open: bool = False
    step_timeout_ms: int = 6000

    @classmethod
    def from_dict(cls, d: dict) -> "DriveCfg":
        base = cls()
        return cls(
            mode=Mode(str(d.get("mode", base.mode.value)).lower()),
            product_url=str(d.get("product_url", "")),
            variant=str(d.get("variant", "")),
            quantity=int(d.get("quantity", 1)),
            expected_price=float(d.get("expected_price", 0.0)),
            price_tolerance=float(d.get("price_tolerance", 0.02)),
            payment_method=str(d.get("payment_method", "")),
            address_label=str(d.get("address_label", "")),
            selectors_path=str(d.get("selectors_path", "")),
            keep_open=bool(d.get("keep_open", False)),
            step_timeout_ms=int(d.get("step_timeout_ms", 6000)),
        )


@dataclass(frozen=True)
class Extras:
    ui: UiCfg = field(default_factory=UiCfg)
    captcha: CaptchaCfg = field(default_factory=CaptchaCfg)
    otp: OtpCfg = field(default_factory=OtpCfg)
    drive: DriveCfg = field(default_factory=DriveCfg)
    bypass: BypassCfg = field(default_factory=BypassCfg)


def load_dict(raw: dict) -> Extras:
    ui = raw.get("ui") or {}
    cap = raw.get("captcha") or {}
    otp = raw.get("otp") or {}
    drv = raw.get("drive") or {}
    byp = raw.get("bypass") or {}
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
        drive=DriveCfg.from_dict(drv),
        bypass=BypassCfg(str(byp.get("channel", "chrome")),
                         str(byp.get("executable", "")),
                         bool(byp.get("native_ua", True)),
                         bool(byp.get("fp_strict", True))),
    )


def load(path: str | Path) -> Extras:
    return load_dict(yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {})
'@

Write-Host ""
Write-Host "2/4 gate.py (brand normalisation)" -ForegroundColor Cyan

W "shopee_sniper/fingerprint/gate.py" @'
"""Contradiction checks.

Every entry is a pair of surfaces a real browser keeps in agreement. One
mismatch is survivable; the set of them together is what produces the
'Please Try Again Later' wall.
"""
from __future__ import annotations

from .profile import Profile

MAX_VIEWPORT_SLACK = 2


def _brand_names(raw) -> list[str]:
    """navigator.userAgentData.brands serialises to a list of dicts, but a
    hand-written fixture may use pairs or bare strings. Accept all three."""
    out: list[str] = []
    for entry in raw or []:
        if isinstance(entry, dict):
            out.append(str(entry.get("brand") or ""))
        elif isinstance(entry, (list, tuple)):
            out.append(str(entry[0]) if entry else "")
        else:
            out.append(str(entry))
    return [b for b in out if b]


def consistency(prof: Profile, actual: dict) -> list[str]:
    fails: list[str] = []

    def eq(name: str, want, got, note: str = "") -> None:
        if want != got:
            fails.append(f"{name}: want {want!r} got {got!r}"
                         + (f" ({note})" if note else ""))

    eq("navigator.webdriver", False, actual.get("webdriver"),
       "must be false, not undefined")
    eq("navigator.userAgent", prof.ua, actual.get("ua"))
    eq("navigator.platform", prof.platform, actual.get("platform"))
    eq("hardwareConcurrency", prof.hardware_concurrency, actual.get("cores"))
    eq("deviceMemory", prof.device_memory, actual.get("memory"))
    eq("languages", list(prof.languages), actual.get("languages"))
    eq("maxTouchPoints", prof.touch_points, actual.get("touch"))
    eq("devicePixelRatio", prof.dpr, actual.get("dpr"))
    eq("screen.width", prof.screen_w, actual.get("screen_w"))
    eq("screen.height", prof.screen_h, actual.get("screen_h"))
    eq("screen.availHeight", prof.avail_height, actual.get("avail_h"))
    eq("timezone", prof.timezone, actual.get("tz"))
    eq("webgl vendor", prof.gpu_vendor, actual.get("gl_vendor"))
    eq("webgl renderer", prof.gpu_renderer, actual.get("gl_renderer"))

    if actual.get("canvas_a") != actual.get("canvas_b"):
        fails.append("canvas hash unstable across two reads of the same canvas")

    if isinstance(actual.get("inner_w"), int):
        if abs(actual["inner_w"] - prof.width) > MAX_VIEWPORT_SLACK:
            fails.append(
                f"innerWidth {actual['inner_w']} vs profile {prof.width} "
                "(monitor clamp or zoom mismatch)")
    if isinstance(actual.get("outer_w"), int) and isinstance(actual.get("inner_w"), int):
        if actual["outer_w"] < actual["inner_w"]:
            fails.append("outerWidth < innerWidth")

    if (actual.get("plugins") or 0) < 4:
        fails.append(f"navigator.plugins only {actual.get('plugins')} entries")
    if not actual.get("chrome_runtime"):
        fails.append("window.chrome.runtime missing")
    if actual.get("pdf") is not True:
        fails.append("navigator.pdfViewerEnabled not true")
    if not actual.get("perm_is_eventtarget"):
        fails.append("permissions.query result is not an EventTarget")
    if "native code" not in (actual.get("perm_tostring") or ""):
        fails.append("permissions.query does not stringify as native")

    brands = _brand_names(actual.get("brands"))
    if not brands:
        fails.append("navigator.userAgentData.brands empty or absent")
    else:
        if "Google Chrome" not in brands:
            fails.append(f"userAgentData.brands lacks Google Chrome: {brands}")
        if "Chromium" not in brands:
            fails.append(f"userAgentData.brands lacks Chromium: {brands}")

    return fails
'@

Write-Host ""
Write-Host "3/4 detect.py (URL-first classification)" -ForegroundColor Cyan

W "shopee_sniper/captcha/detect.py" @'
"""Challenge classification.

Two distinct failures live behind the same URL:

  HARD  /verify/captcha renders 'Please Try Again Later' with no slider. The
        session was rejected outright; the token is dead and a 120ms retry
        re-uses a burned context. Needs a cooldown and an IP quarantine.
  SOFT  a real slider is on the page. That is solvable in place.

Page classification keys off the URL first. Shopee inlines its whole JS bundle,
so a substring match against page.content() hits 'risk_control' and 'captcha' on
every page - markers are only consulted as a fallback.
"""
from __future__ import annotations

import enum


class Outcome(enum.Enum):
    OK = "OK"
    BUSY = "BUSY"
    CHALLENGE = "CHALLENGE"
    HARD_BLOCK = "HARD_BLOCK"
    BANNED = "BANNED"
    FAIL = "FAIL"


# Rendered text, not bundle identifiers.
HARD_TEXT = (
    "Please Try Again Later",
    "try again after a few minutes",
    "Please try again later",
)
# DOM markers, only trusted on the challenge page itself.
SLIDER_MARKERS = (
    "slider-handle",
    "captcha-slider",
    "captcha-bg",
    "captcha-puzzle",
)
BANNED_MARKERS = ("account_frozen", "account frozen", "frozen", "banned",
                  "permanently blocked")
BUSY_MARKERS = ("System busy", "system_busy", "too many requests")
ORDER_MARKERS = ('"order_id"', '"ordersn"', '"order_sn"')


def by_url(url: str) -> bool:
    return "/verify/captcha" in url


def _hit(body: str, markers: tuple[str, ...]) -> bool:
    return any(m in body for m in markers)


def _has_order(body: str) -> bool:
    return _hit(body, ORDER_MARKERS)


def classify_page(url: str, html: str) -> Outcome:
    """Page-level verdict.

    Off the challenge URL, only a slider or the explicit card counts. On the
    challenge URL, the absence of a slider *is* the verdict - no marker needed.
    """
    if by_url(url):
        if _hit(html, SLIDER_MARKERS):
            return Outcome.CHALLENGE
        if _hit(html, BANNED_MARKERS):
            return Outcome.BANNED
        return Outcome.HARD_BLOCK
    if _hit(html, SLIDER_MARKERS):
        return Outcome.CHALLENGE
    if _hit(html, HARD_TEXT):
        return Outcome.HARD_BLOCK
    if _hit(html, BANNED_MARKERS):
        return Outcome.BANNED
    return Outcome.OK


def classify(status: int, body: str) -> Outcome:
    """Response-level verdict for a fired shot.

    A body carrying an order id is a success even when it also mentions
    anti_bot_tracking_id, which Shopee attaches to plenty of healthy responses.
    """
    if 200 <= status < 300:
        if _has_order(body):
            return Outcome.OK
        if _hit(body, HARD_TEXT):
            return Outcome.HARD_BLOCK
        return Outcome.CHALLENGE if _hit(body, SLIDER_MARKERS) else Outcome.OK
    if status == 403:
        if _hit(body, BANNED_MARKERS):
            return Outcome.BANNED
        if _hit(body, HARD_TEXT):
            return Outcome.HARD_BLOCK
        return Outcome.CHALLENGE
    if status == 429:
        return Outcome.HARD_BLOCK
    if 500 <= status < 600:
        return Outcome.BUSY
    if status == 0:
        return Outcome.BUSY
    if _hit(body, HARD_TEXT):
        return Outcome.HARD_BLOCK
    if _hit(body, SLIDER_MARKERS):
        return Outcome.CHALLENGE
    if _hit(body, BUSY_MARKERS):
        return Outcome.BUSY
    return Outcome.FAIL
'@

Write-Host ""
Write-Host "4/4 fpcheck.py (full rewrite, json literal)" -ForegroundColor Cyan

W "tools/fpcheck.py" @'
"""Gate: does the browser agree with itself?

Launches one bot's browser against a local origin, reads ~30 surfaces, and fails
on any contradiction. --headers also prints the raw request header block so
duplicate client hints and ordering are visible.

Run this before every sale. A green fpcheck plus a green captcha probe is the
difference between 'blocked' and 'slow'.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from shopee_sniper import config, settings
from shopee_sniper.fingerprint import gate, probe
from shopee_sniper.fingerprint import profile as fp


class Echo(BaseHTTPRequestHandler):
    seen: list[list[tuple[str, str]]] = []

    def log_message(self, *a) -> None:
        pass

    def do_GET(self) -> None:
        if self.path == "/echo":
            Echo.seen.append(list(self.headers.items()))
        body = b"<html><body>ok</body></html>"
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve() -> tuple[ThreadingHTTPServer, int]:
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Echo)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_port


async def run(config_path: str, headers: bool) -> int:
    cfg = config.load(config_path)
    extra = settings.load(config_path)
    bp = extra.bypass
    bot = cfg.bots[0]
    prof = fp.load_or_mint(bot.profile_path, bot.id, bp.executable,
                           refresh_geometry=True)

    srv, port = serve()
    base = f"http://127.0.0.1:{port}"
    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    kwargs = fp.context_args(prof, None, bp.native_ua)
    launch: dict = {"headless": False, "args": fp.launch_args(prof, (60, 60))}
    if bp.executable:
        launch["executable_path"] = bp.executable
    elif bp.channel:
        launch["channel"] = bp.channel
    ctx = await pw.chromium.launch_persistent_context(
        user_data_dir=str(Path(bot.profile_path).with_suffix("")),
        **launch, **kwargs)
    try:
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        body = Path(fp.__file__).with_name("patches.js").read_text(encoding="utf-8")
        await page.add_init_script(
            script=f"window.__FP__={json.dumps(prof.stealth_cfg())};\n{body}")
        await page.goto(f"{base}/", wait_until="load")
        actual = probe.dump(page)

        fails = gate.consistency(prof, actual)
        width = max(len(k) for k in actual)
        for k in sorted(actual):
            v = actual[k]
            if isinstance(v, str) and len(v) > 78:
                v = v[:75] + "..."
            print(f"  {k.ljust(width)}  {v}")

        if headers:
            await page.goto(f"{base}/echo", wait_until="load")
            await page.wait_for_timeout(400)
            print("\n  request headers as sent:")
            names = []
            for block in Echo.seen:
                for n, v in block:
                    print(f"    {n}: {v[:90]}")
                    names.append(n.lower())
            dupes = {n for n in names if names.count(n) > 1}
            if dupes:
                fails.append(f"duplicate request headers: {sorted(dupes)}")

        print()
        if fails:
            for f in fails:
                print(f"  FAIL {f}")
            print(f"\n  {len(fails)} contradiction(s)")
            return 1
        print("  OK  no contradictions")
        return 0
    finally:
        await ctx.close()
        await pw.stop()
        srv.shutdown()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--headers", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.config, a.headers))


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-Host ""
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) and compileall.compile_dir('tools', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
Write-Host "  OK compiles" -ForegroundColor Green
Write-Host ""
Write-Host "then:" -ForegroundColor Green
Write-Host "  python -m pytest -q"
Write-Host "  python -m tools.fpcheck --headers"