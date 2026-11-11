# bypass2.ps1 -- resume from the failed anchor in section 7.
#
# Only the work that never ran. S() is now idempotent: if the replacement text
# is already present the file is skipped, so a re-run is safe.

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
if (-not (Test-Path (Join-Path $root 'shopee_sniper'))) {
  throw "run this from the repo root"
}
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

function S($rel, $from, $to) {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) { throw "missing file $rel" }
  $t = [System.IO.File]::ReadAllText($p)
  if ($t.Contains($to)) { Write-Host "  = $rel (already applied)"; return }
  if (-not $t.Contains($from)) { throw "anchor not found in ${rel}:" + "`n" + $from }
  $b = Join-Path $backup $rel
  New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
  Copy-Item $p $b -Force
  [System.IO.File]::WriteAllText($p, $t.Replace($from, $to), $enc)
  Write-Host "  S $rel"
}

Write-Host ""
Write-Host "1/6 config: bypass section" -ForegroundColor Cyan

S "shopee_sniper/config.py" 'from dataclasses import dataclass' 'from dataclasses import dataclass, field'

# BypassCfg must be defined BEFORE Config: default_factory is evaluated while the
# Config class body executes, so a forward reference would NameError.
S "shopee_sniper/config.py" @'
@dataclass(frozen=True)
class Config:'@ @'
@dataclass(frozen=True)
class BypassCfg:
    """Everything the anti-bot layer needs to be steered from config."""

    channel: str = "chrome"
    executable: str = ""
    native_ua: bool = True
    fp_strict: bool = True
    require_residential: bool = True
    allow_countries: tuple[str, ...] = ()
    hard_block_cooldown_s: float = 45.0
    hard_block_max: int = 2


@dataclass(frozen=True)
class Config:'@

S "shopee_sniper/config.py" @'
    sidecar_url: str
    bots: tuple[Bot, ...]'@ @'
    sidecar_url: str
    bots: tuple[Bot, ...]
    bypass: BypassCfg = field(default_factory=BypassCfg)'@

S "shopee_sniper/config.py" @'
    s, t, p, l, h = (raw["sale"], raw["timing"], raw["proxy"],
                     raw["limits"], raw["harvest"])'@ @'
    s, t, p, l, h = (raw["sale"], raw["timing"], raw["proxy"],
                     raw["limits"], raw["harvest"])
    b = raw.get("bypass") or {}'@

S "shopee_sniper/config.py" @'
        sidecar_url=str(raw["sidecar"]["url"]),'@ @'
        bypass=BypassCfg(
            channel=str(b.get("channel", "chrome")),
            executable=str(b.get("executable", "")),
            native_ua=bool(b.get("native_ua", True)),
            fp_strict=bool(b.get("fp_strict", True)),
            require_residential=bool(b.get("require_residential", True)),
            allow_countries=tuple(b.get("allow_countries") or ()),
            hard_block_cooldown_s=float(b.get("hard_block_cooldown_s", 45.0)),
            hard_block_max=int(b.get("hard_block_max", 2)),
        ),
        sidecar_url=str(raw["sidecar"]["url"]),'@

Write-Host ""
Write-Host "2/6 settings: optional bypass mirror" -ForegroundColor Cyan

S "shopee_sniper/settings.py" @'
@dataclass(frozen=True)
class Extras:
    ui: UiCfg = field(default_factory=UiCfg)'@ @'
@dataclass(frozen=True)
class BypassCfg:
    channel: str = "chrome"
    executable: str = ""
    native_ua: bool = True
    fp_strict: bool = True


@dataclass(frozen=True)
class Extras:
    ui: UiCfg = field(default_factory=UiCfg)
    bypass: BypassCfg = field(default_factory=BypassCfg)'@

S "shopee_sniper/settings.py" @'
    drv = raw.get("drive") or {}
    return Extras('@ @'
    drv = raw.get("drive") or {}
    byp = raw.get("bypass") or {}
    return Extras(
        bypass=BypassCfg(str(byp.get("channel", "chrome")),
                         str(byp.get("executable", "")),
                         bool(byp.get("native_ua", True)),
                         bool(byp.get("fp_strict", True))),'@

Write-Host ""
Write-Host "3/6 squad + race: IP policy and hard-block reaction" -ForegroundColor Cyan

S "shopee_sniper/orchestrator/squad.py" @'
        self.pool.preflight_all([b.proxy for b in self.cfg.bots])'@ @'
        self.pool.require_residential = self.cfg.bypass.require_residential
        self.pool.allow_countries = self.cfg.bypass.allow_countries
        self.pool.region = self.cfg.sale.region
        self.pool.preflight_all([b.proxy for b in self.cfg.bots])'@

S "shopee_sniper/orchestrator/race.py" @'
                 fire_fn: FireFn | None = None, hard_timeout_s: float = 25.0) -> None:'@ @'
                 fire_fn: FireFn | None = None, hard_timeout_s: float = 25.0,
                 on_hard_block: Callable[[str], None] | None = None) -> None:'@

S "shopee_sniper/orchestrator/race.py" @'
        self.fire_fn = fire_fn
        self.hard_timeout_s = hard_timeout_s'@ @'
        self.fire_fn = fire_fn
        self.hard_timeout_s = hard_timeout_s
        self.on_hard_block = on_hard_block'@

S "shopee_sniper/orchestrator/race.py" @'
            kind = classify(res.status, res.body)
            if kind is Outcome.CHALLENGE:'@ @'
            kind = classify(res.status, res.body)
            if kind is Outcome.HARD_BLOCK:
                # The session is rejected outright: the token is dead and a
                # 120ms retry re-uses a burned context. Quarantine the exit,
                # cool off, and only retry while budget remains.
                self.log.write(bot_id=p.bot_id, event="hard_block",
                               status=res.status)
                if self.on_hard_block:
                    self.on_hard_block(p.bot_id)
                if p.session.retries < self.cfg.bypass.hard_block_max:
                    p.session.retries += 1
                    await asyncio.sleep(self.cfg.bypass.hard_block_cooldown_s)
                    target_ns = clock.now_ns() + 200_000
                    continue
                p.session.fail("hard block")
                return
            if kind is Outcome.CHALLENGE:'@

Write-Host ""
Write-Host "4/6 runner: land before warm, survive a block, wire the callback" -ForegroundColor Cyan

S "shopee_sniper/orchestrator/run.py" @'
        rt = runtimes.get(bot_id)
        if rt:
            if warm_min:
                await rt.warm(warm_min)
            await rt.to_ready()'@ @'
        rt = runtimes.get(bot_id)
        if rt:
            try:
                await rt.land()
                if warm_min:
                    await rt.warm(warm_min)
                await rt.to_ready()
            except Exception as exc:
                # One blocked bot must not abort the whole preparation pass.
                log.write(bot_id=bot_id, event="prepare_failed", error=repr(exc))
                store.upsert(bot_id, state="FAILED", handoff=repr(exc))
                continue'@

S "shopee_sniper/orchestrator/run.py" @'
            race = Race(cfg, log, el, ttl_safe, cfg.sidecar_url,
                        f"shopee.{cfg.sale.region}",
                        cfg.timing.ingest_est_ms * 1_000_000)'@ @'
            race = Race(cfg, log, el, ttl_safe, cfg.sidecar_url,
                        f"shopee.{cfg.sale.region}",
                        cfg.timing.ingest_est_ms * 1_000_000,
                        on_hard_block=sq.pool.quarantine)'@

S "tools/drive.py" @'
        await rt.start(pw, (60, 60))
        total = await rt.to_ready()'@ @'
        await rt.start(pw, (60, 60))
        await rt.land()
        total = await rt.to_ready()'@

Write-Host ""
Write-Host "5/6 new tools and tests" -ForegroundColor Cyan

W "shopee_sniper/fingerprint/__init__.py" @'
"""Phase 1: identity resolution, document-start stealth, contradiction gate."""

from . import env, gate, probe
from .profile import Profile

__all__ = ["env", "gate", "probe", "Profile"]
'@

W "tools/captcha_probe.py" @'
"""Gate: can this identity and this exit IP load Shopee without a wall?

Navigates the homepage, optionally a product page, and reports the verdict.
Exit 0 means OK or a solvable slider. This is the cheapest way to test a bypass
change - no sale, no sidecar, no timing.

    python -m tools.captcha_probe --config config/bots.yaml --product
"""
from __future__ import annotations

import argparse
import asyncio

from shopee_sniper import config, settings
from shopee_sniper.bot import BotRuntime
from shopee_sniper.captcha.detect import Outcome
from shopee_sniper.log import JsonlLog
from shopee_sniper.session import warmup
from shopee_sniper.settings import DriveCfg
from shopee_sniper.ui.store import Store


async def run(config_path: str, product: bool, keep: bool) -> int:
    cfg = config.load(config_path)
    extra = settings.load(config_path)
    log = JsonlLog("logs/probe.jsonl")
    store = Store()
    bot = cfg.bots[0]
    rt = BotRuntime(cfg, bot, log, store, DriveCfg())

    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    verdict = Outcome.FAIL
    try:
        await rt.start(pw, (60, 60))
        await rt.land()
        await asyncio.sleep(3)
        verdict = await warmup.probe(rt.page)
        print(f"homepage  {verdict.value}")
        if product and verdict is Outcome.OK and extra.drive.product_url:
            await rt.page.goto(extra.drive.product_url,
                               wait_until="domcontentloaded")
            await asyncio.sleep(3)
            verdict = await warmup.probe(rt.page)
            print(f"product   {verdict.value}")
        print(f"\nurl  {rt.page.url}")
        if verdict is Outcome.HARD_BLOCK:
            print("\n  HARD BLOCK - identity or exit IP. Run fpcheck, then check the ASN.")
        elif verdict is Outcome.CHALLENGE:
            print("\n  slider present - identity accepted, solvable.")
    except warmup.Blocked as exc:
        verdict = exc.outcome
        print(f"blocked on arrival: {verdict.value}")
    finally:
        await rt.close(keep_open=keep)
        if keep:
            await asyncio.to_thread(input, "enter to close ")
        await pw.stop()
    return 0 if verdict in (Outcome.OK, Outcome.CHALLENGE) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--product", action="store_true")
    ap.add_argument("--keep-open", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.config, a.product, a.keep_open))


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tests/test_bypass.py" @'
from shopee_sniper.captcha.detect import Outcome, classify, classify_page
from shopee_sniper.fingerprint import gate
from shopee_sniper.fingerprint.profile import Profile

HARD_HTML = ("<div>Please Try Again Later</div>"
             "<div>Please try again after a few minutes.</div>")
SLIDER_HTML = '<div class="captcha-bg"></div><div class="slider-handle"></div>'


def test_hard_block_beats_slider_marker() -> None:
    """The block page carries 'captcha' in its URL. It must not be routed to a
    slider solver that is not on the page."""
    assert classify_page(
        "https://x/verify/captcha?anti_bot_tracking_id=1",
        HARD_HTML) is Outcome.HARD_BLOCK


def test_slider_page_is_challenge() -> None:
    assert classify_page("https://x/verify/captcha", SLIDER_HTML) is Outcome.CHALLENGE


def test_clean_page_is_ok() -> None:
    assert classify_page("https://shopee.my/", "<div>home</div>") is Outcome.OK


def test_403_hard_marker() -> None:
    assert classify(403, HARD_HTML) is Outcome.HARD_BLOCK


def test_429_is_hard() -> None:
    assert classify(429, "") is Outcome.HARD_BLOCK


def test_frozen_still_banned() -> None:
    assert classify(403, "account frozen") is Outcome.BANNED


def _prof() -> Profile:
    return Profile(
        seed="b1", ua="UA", chrome_major=131, chrome_version="131.0.6778.86",
        platform="Win32", ch_platform="Windows", width=1600, height=900,
        screen_w=1920, screen_h=1080, dpr=1.0, locale="en-MY",
        timezone="Asia/Kuala_Lumpur", gpu_vendor="Google Inc. (NVIDIA)",
        gpu_renderer="ANGLE (NVIDIA)", hardware_concurrency=8, device_memory=8,
        canvas_seed=1, audio_seed=2, languages=("en-MY", "en"))


def _actual(**over) -> dict:
    base = dict(webdriver=False, ua="UA", platform="Win32", cores=8, memory=8,
                languages=["en-MY", "en"], touch=0, dpr=1.0, screen_w=1920,
                screen_h=1080, avail_h=1032, inner_w=1600, outer_w=1600,
                tz="Asia/Kuala_Lumpur", gl_vendor="Google Inc. (NVIDIA)",
                gl_renderer="ANGLE (NVIDIA)", canvas_a="a", canvas_b="a",
                plugins=5, chrome_runtime=True, pdf=True,
                perm_is_eventtarget=True,
                perm_tostring="function query() { [native code] }",
                brands=[{"brand": "Chromium"}, {"brand": "Not_A Brand"},
                        {"brand": "Google Chrome"}])
    base.update(over)
    return base


def test_clean_profile_passes() -> None:
    assert gate.consistency(_prof(), _actual()) == []


def test_webdriver_undefined_fails() -> None:
    assert any("webdriver" in f
               for f in gate.consistency(_prof(), _actual(webdriver=None)))


def test_unstable_canvas_fails() -> None:
    assert any("canvas" in f for f in gate.consistency(_prof(), _actual(canvas_b="b")))


def test_swiftshader_fails() -> None:
    out = gate.consistency(_prof(), _actual(gl_renderer="ANGLE (Google, Vulkan SwiftShader)"))
    assert any("renderer" in f for f in out)


def test_missing_chrome_brand_fails() -> None:
    out = gate.consistency(_prof(), _actual(brands=[{"brand": "Chromium"}]))
    assert any("Google Chrome" in f for f in out)


def test_screen_mismatch_fails() -> None:
    assert any("screen.width" in f
               for f in gate.consistency(_prof(), _actual(screen_w=1366)))


def test_permissions_not_eventtarget_fails() -> None:
    assert any("EventTarget" in f
               for f in gate.consistency(_prof(), _actual(perm_is_eventtarget=False)))
'@

# fpcheck.py used repr() for the config literal, which emits Python False/None
# instead of JS false/null. Rewrite the injection line to json.dumps.
S "tools/fpcheck.py" @'
        await page.add_init_script(
            script=f"window.__FP__={prof.stealth_cfg()!r};".replace("'", '"')
            + "\n" + (Path(fp.__file__).with_name("patches.js")).read_text())'@ @'
        cfg_literal = json.dumps(prof.stealth_cfg())
        body = Path(fp.__file__).with_name("patches.js").read_text(encoding="utf-8")
        await page.add_init_script(script=f"window.__FP__={cfg_literal};\n{body}")'@

S "tools/fpcheck.py" @'
import argparse
import asyncio
import threading'@ @'
import argparse
import asyncio
import json
import threading'@

Write-Host ""
Write-Host "6/6 config block + preflight" -ForegroundColor Cyan

$block = @'

# Anti-bot layer. channel=chrome runs the installed Chrome, not Playwright's
# bundled Chromium - the bundled binary reports itself as Chromium in client
# hints while a spoofed UA string claims Chrome, which is a free contradiction.
bypass:
  channel: chrome
  executable: ""          # explicit chrome.exe path to override
  native_ua: true         # let Chrome send its own UA and client hints
  fp_strict: true         # refuse to warm up on a contradictory browser
  require_residential: true
  allow_countries: []     # [] means "the sale region's country"
  hard_block_cooldown_s: 45
  hard_block_max: 2
'@

foreach ($rel in @("config/bots.example.yaml", "config/bots.yaml")) {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) { Write-Host "  (skip, no $rel)"; continue }
  $t = [System.IO.File]::ReadAllText($p)
  if ($t -match '(?m)^bypass:') { Write-Host "  = $rel (already has bypass)"; continue }
  $b = Join-Path $backup $rel
  New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
  Copy-Item $p $b -Force
  [System.IO.File]::WriteAllText($p, $t.TrimEnd() + "`n" + $block, $enc)
  Write-Host "  + $rel"
}

Write-Host ""
Write-Host "compile check" -ForegroundColor Cyan
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) and compileall.compile_dir('tools', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed - see above" }
Write-Host "  OK all modules compile" -ForegroundColor Green

Write-Host ""
Write-Host "backups: .backup/$stamp" -ForegroundColor DarkGray
Write-Host ""
Write-Host "then:" -ForegroundColor Green
Write-Host "  python -m pytest -q"
Write-Host "  python -m tools.fpcheck --headers"
Write-Host "  python -m tools.captcha_probe --product"