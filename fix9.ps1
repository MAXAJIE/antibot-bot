# fix9.ps1 -- drop --no-sandbox, make the frame geometry real, and stop
# treating a rate-limit as a verdict.

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
if (-not (Test-Path (Join-Path $root 'shopee_sniper'))) { throw "run this from the repo root" }
$enc = New-Object System.Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $root ".backup/$stamp"

function S($rel, $from, $to) {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) { throw "missing file $rel" }
  $t = [System.IO.File]::ReadAllText($p) -replace "`r`n", "`n"
  $f = $from -replace "`r`n", "`n"
  $r = $to -replace "`r`n", "`n"
  $hasAnchor = $t.Contains($f)
  if (-not $hasAnchor -and $t.Contains($r)) { Write-Host "  = $rel (already applied)"; return }
  $idx = -1; $len = 0
  if ($hasAnchor) { $idx = $t.IndexOf($f); $len = $f.Length }
  else {
    $pat = (($f -split "`n") | ForEach-Object { [regex]::Escape($_) -replace '(\\ )+', '\s+' }) -join '\s*\n\s*'
    $m = [regex]::Match($t, $pat)
    if ($m.Success) { $idx = $m.Index; $len = $m.Length }
  }
  if ($idx -lt 0) { throw "anchor not found in ${rel}:`n$f" }
  $b = Join-Path $backup $rel
  New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
  Copy-Item $p $b -Force
  [System.IO.File]::WriteAllText($p, $t.Substring(0, $idx) + $r + $t.Substring($idx + $len), $enc)
  Write-Host "  S $rel"
}

Write-Host ""
Write-Host "1/5 sandbox on" -ForegroundColor Cyan

$f = @'
        launch: dict = {"headless": False,
                        "args": fp.launch_args(self.prof, position)}
'@
$r = @'
        # chromium_sandbox defaults to False, which adds --no-sandbox and makes
        # Chrome paint the "unsupported command-line flag" banner. A hand-
        # launched Chrome has neither.
        launch: dict = {"headless": False, "chromium_sandbox": True,
                        "args": fp.launch_args(self.prof, position)}
'@
S "shopee_sniper/bot.py" $f $r

$f = @'
    launch: dict = {"headless": False, "args": fp.launch_args(prof, (60, 60))}
'@
$r = @'
    launch: dict = {"headless": False, "chromium_sandbox": True,
                    "args": fp.launch_args(prof, (60, 60))}
'@
S "tools/fpcheck.py" $f $r

Write-Host ""
Write-Host "2/5 frame overhead" -ForegroundColor Cyan

$f = @'
LOCALES = [("en-MY", "Asia/Kuala_Lumpur"), ("en-SG", "Asia/Singapore"),
'@
$r = @'
# Windows 11 at 100% DPI: 8px border each side, ~31px title bar, 40px tab strip,
# 40px omnibox. outerWidth is the window; innerWidth is what is left of it.
# Equality between the two is impossible in a real window and is what a forced
# viewport produces.
FRAME_X = 16
FRAME_Y = 120

LOCALES = [("en-MY", "Asia/Kuala_Lumpur"), ("en-SG", "Asia/Singapore"),
'@
S "shopee_sniper/fingerprint/profile.py" $f $r

$f = @'
    @property
    def accept_language(self) -> str:
'@
$r = @'
    @property
    def inner_width(self) -> int:
        return self.width - FRAME_X

    @property
    def inner_height(self) -> int:
        return self.height - FRAME_Y

    @property
    def accept_language(self) -> str:
'@
S "shopee_sniper/fingerprint/profile.py" $f $r

$f = @'
        "viewport": {"width": prof.width, "height": prof.height},
'@
$r = @'
        # None: let the window decide. A forced viewport equal to the window
        # size erases the frame, and innerWidth == outerWidth is a tell.
        "viewport": None,
'@
S "shopee_sniper/fingerprint/profile.py" $f $r

Write-Host ""
Write-Host "3/5 gate the frame" -ForegroundColor Cyan

$f = @'
    if isinstance(actual.get("inner_w"), int):
        if abs(actual["inner_w"] - prof.width) > MAX_VIEWPORT_SLACK:
            fails.append(
                f"innerWidth {actual['inner_w']} vs profile {prof.width} "
                "(monitor clamp or zoom mismatch)")
    if isinstance(actual.get("outer_w"), int) and isinstance(actual.get("inner_w"), int):
        if actual["outer_w"] < actual["inner_w"]:
            fails.append("outerWidth < innerWidth")
'@
$r = @'
    if isinstance(actual.get("inner_w"), int):
        if abs(actual["inner_w"] - prof.inner_width) > MAX_VIEWPORT_SLACK:
            fails.append(
                f"innerWidth {actual['inner_w']} vs profile {prof.inner_width} "
                "(monitor clamp or zoom mismatch)")
    if isinstance(actual.get("outer_w"), int) and isinstance(actual.get("inner_w"), int):
        dx = actual["outer_w"] - actual["inner_w"]
        if dx < 8 or dx > 40:
            fails.append(f"outerWidth - innerWidth is {dx}, no real frame has that")
'@
S "shopee_sniper/fingerprint/gate.py" $f $r

Write-Host ""
Write-Host "4/5 tests follow the geometry" -ForegroundColor Cyan

$f = @'
                screen_h=1080, avail_h=1032, inner_w=1600, outer_w=1600,
'@
$r = @'
                screen_h=1080, avail_h=1032, inner_w=1584, outer_w=1600,
'@
S "tests/test_bypass.py" $f $r

$f = @'
def test_permissions_not_eventtarget_fails() -> None:
    assert any("EventTarget" in f
               for f in gate.consistency(_prof(), _actual(perm_is_eventtarget=False)))
'@
$r = @'
def test_permissions_not_eventtarget_fails() -> None:
    assert any("EventTarget" in f
               for f in gate.consistency(_prof(), _actual(perm_is_eventtarget=False)))


def test_equal_inner_outer_fails() -> None:
    """A forced viewport erases the window frame."""
    assert any("frame" in f
               for f in gate.consistency(_prof(), _actual(inner_w=1600, outer_w=1600)))
'@
S "tests/test_bypass.py" $f $r

Write-Host ""
Write-Host "5/5 cooldown retry and diagnosis in the probe" -ForegroundColor Cyan

$f = @'
    bot = cfg.bots[0]
    rt = BotRuntime(cfg, bot, log, store, DriveCfg())
'@
$r = @'
    bot = cfg.bots[0]
    print(f"proxy     {bot.proxy or '(direct - host IP)'}")
    rt = BotRuntime(cfg, bot, log, store, DriveCfg())
'@
S "tools/captcha_probe.py" $f $r

$f = @'
        await rt.land()
        await asyncio.sleep(3)
        verdict = await warmup.probe(rt.page)
        print(f"homepage  {verdict.value}")
'@
$r = @'
        await rt.land()
        await asyncio.sleep(3)
        verdict = await warmup.probe(rt.page)
        print(f"homepage  {verdict.value}")
        if verdict is Outcome.HARD_BLOCK:
            # A hard block is reputation and rate, not fingerprint: the same
            # identity usually clears once the exit stops being hammered.
            # Retrying inside the cooldown just re-burns it.
            print(f"  cooling off {cfg.bypass.hard_block_cooldown_s:.0f}s, one retry")
            await asyncio.sleep(cfg.bypass.hard_block_cooldown_s)
            await rt.page.goto(rt.base, wait_until="domcontentloaded")
            await asyncio.sleep(3)
            verdict = await warmup.probe(rt.page)
            print(f"retry     {verdict.value}")
'@
S "tools/captcha_probe.py" $f $r

$f = @'
        if verdict is Outcome.HARD_BLOCK:
            print("\n  HARD BLOCK - identity or exit IP. Run fpcheck, then check the ASN.")
'@
$r = @'
        if verdict is Outcome.HARD_BLOCK:
            print("\n  HARD BLOCK. fpcheck was green, so this is the exit, not the")
            print("  identity: datacenter ASN, or the IP is rate-limited. Home")
            print("  broadband in the sale country clears; a DC proxy will not.")
'@
S "tools/captcha_probe.py" $f $r

Write-Host ""
Write-Host "check" -ForegroundColor Cyan
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) and compileall.compile_dir('tools', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
& python -m pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest regressed" }
Write-Host "  tests green" -ForegroundColor Green