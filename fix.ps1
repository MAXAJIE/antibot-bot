# fix3.ps1 -- detect.py rewritten whole, probe async, callers awaited.

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

# CRLF-tolerant: try the text as given, then LF-normalised.
function S($rel, $from, $to) {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) { throw "missing file $rel" }
  $t = [System.IO.File]::ReadAllText($p)
  if ($t.Contains($to)) { Write-Host "  = $rel (already applied)"; return }
  $lfFrom = $from -replace "`r`n", "`n"
  $lfTo = $to -replace "`r`n", "`n"
  if ($t.Contains($lfFrom)) { $hit = $lfFrom; $rep = $lfTo }
  elseif ($t.Contains($from)) { $hit = $from; $rep = $to }
  else { throw "anchor not found in ${rel}:" + "`n" + $from }
  $b = Join-Path $backup $rel
  New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
  Copy-Item $p $b -Force
  [System.IO.File]::WriteAllText($p, $t.Replace($hit, $rep), $enc)
  Write-Host "  S $rel"
}

Write-Host ""
Write-Host "1/2 detect.py (full rewrite)" -ForegroundColor Cyan

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

API classification is separate: an API body carries identifiers, not CSS class
names, so it gets its own marker set and a leading order-id short-circuit.
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
# API bodies carry identifiers. Kept apart from SLIDER_MARKERS so a page bundle
# full of class names cannot match through this path.
API_CHALLENGE_MARKERS = ("risk_control", "riskControl", "captcha", "anti_bot",
                         "verify_captcha")


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
        if _hit(body, API_CHALLENGE_MARKERS):
            return Outcome.CHALLENGE
        return Outcome.OK
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
    if _hit(body, API_CHALLENGE_MARKERS) or _hit(body, SLIDER_MARKERS):
        return Outcome.CHALLENGE
    if _hit(body, BUSY_MARKERS):
        return Outcome.BUSY
    return Outcome.FAIL
'@

Write-Host ""
Write-Host "2/2 probe async + callers await" -ForegroundColor Cyan

W "shopee_sniper/fingerprint/probe.py" @'
"""Collect every surface the gate checks, from inside the page."""
from __future__ import annotations

import json

# Returns a promise; page.evaluate resolves it before handing the value back.
PROBE = r"""
() => {
  const gl = (() => {
    try {
      const c = document.createElement("canvas");
      const g = c.getContext("webgl") || c.getContext("experimental-webgl");
      if (!g) return ["", ""];
      const d = g.getExtension("WEBGL_debug_renderer_info");
      return [
        String(g.getParameter(d ? d.UNMASKED_VENDOR_WEBGL : 0x1F00)),
        String(g.getParameter(d ? d.UNMASKED_RENDERER_WEBGL : 0x1F01)),
      ];
    } catch (e) { return ["", ""]; }
  })();

  const canvas = (() => {
    try {
      const c = document.createElement("canvas");
      c.width = 240; c.height = 60;
      const x = c.getContext("2d");
      x.textBaseline = "top";
      x.font = "14px Arial";
      x.fillStyle = "#f60";
      x.fillRect(0, 0, 120, 20);
      x.fillStyle = "#069";
      x.fillText("Shopee fingerprint 1234", 2, 15);
      return [c.toDataURL(), c.toDataURL()];
    } catch (e) { return ["", ""]; }
  })();

  let permStr = "";
  try {
    permStr = Function.prototype.toString.call(navigator.permissions.query);
  } catch (e) {}

  return (async () => {
    let permIsTarget = false;
    try {
      const r = await navigator.permissions.query({ name: "notifications" });
      permIsTarget = !!r && typeof r.addEventListener === "function";
    } catch (e) {}

    let webglExt = false;
    try {
      const g = document.createElement("canvas").getContext("webgl");
      webglExt = !!g && g.getSupportedExtensions()
        .indexOf("WEBGL_debug_renderer_info") >= 0;
    } catch (e) {}

    return {
      webdriver: navigator.webdriver,
      ua: navigator.userAgent,
      platform: navigator.platform,
      vendor: navigator.vendor,
      cores: navigator.hardwareConcurrency,
      memory: navigator.deviceMemory,
      languages: Array.from(navigator.languages),
      touch: navigator.maxTouchPoints,
      dpr: window.devicePixelRatio,
      screen_w: screen.width,
      screen_h: screen.height,
      avail_h: screen.availHeight,
      inner_w: innerWidth,
      inner_h: innerHeight,
      outer_w: outerWidth,
      outer_h: outerHeight,
      tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      tz_offset: new Date().getTimezoneOffset(),
      gl_vendor: gl[0],
      gl_renderer: gl[1],
      canvas_a: canvas[0],
      canvas_b: canvas[1],
      plugins: navigator.plugins.length,
      mime_types: navigator.mimeTypes.length,
      chrome_runtime: !!(window.chrome && window.chrome.runtime),
      pdf: navigator.pdfViewerEnabled,
      perm_is_eventtarget: permIsTarget,
      perm_tostring: permStr,
      brands: (navigator.userAgentData && navigator.userAgentData.brands) || [],
      ua_mobile: navigator.userAgentData ? navigator.userAgentData.mobile : null,
      ua_platform: navigator.userAgentData ? navigator.userAgentData.platform : null,
      webgl_ext: webglExt,
    };
  })();
}
"""


async def dump(page) -> dict:
    raw = await page.evaluate(PROBE)
    return json.loads(json.dumps(raw))
'@

S "shopee_sniper/bot.py" 'actual = probe.dump(self.page)' 'actual = await probe.dump(self.page)'
S "tools/fpcheck.py" 'actual = probe.dump(page)' 'actual = await probe.dump(page)'

Write-Host ""
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) and compileall.compile_dir('tools', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
Write-Host "  OK compiles" -ForegroundColor Green

Write-Host ""
Write-Host "verifying" -ForegroundColor Cyan
& python -c "from shopee_sniper.captcha.detect import classify, classify_page, Outcome; assert classify(200, '{\"error\":\"risk_control\"}') is Outcome.CHALLENGE; assert classify(200, '{\"order_id\":1}') is Outcome.OK; assert classify_page('https://x/verify/captcha', '<div>Please Try Again Later</div>') is Outcome.HARD_BLOCK; assert classify_page('https://x/', '<div>home</div>') is Outcome.OK; import inspect, shopee_sniper.fingerprint.probe as p; assert inspect.iscoroutinefunction(p.dump); print('  classifier + probe OK')"
if ($LASTEXITCODE -ne 0) { throw "verify failed" }

Write-Host ""
& python -m pytest -q