# fix10.ps1 -- the profile declared physical pixels as CSS pixels.
#
#   innerWidth 1280 vs profile 1584 / outer-inner 320
#
# primary_screen() is DPI-aware, so it returns physical pixels, but the profile
# published them as CSS with dpr hardcoded to 1.0. At 150% scaling the real CSS
# screen is 1280x720 and a 1600px window cannot fit, so Chrome clamps and only
# the faked outerWidth still says 1600.

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
Write-Host "1/3 read the real scale factor" -ForegroundColor Cyan

$f = @'
def primary_screen() -> tuple[int, int]:
'@
$r = @'
def primary_scale() -> float:
    """Windows display scale, 1.0 at 100%.

    Everything CSS-facing (screen.width, innerWidth, window size) is in DIPs.
    primary_screen() is DPI-aware and returns physical pixels, so without this
    divisor the profile claims a viewport the host cannot honour and Chrome
    clamps it behind the faked outerWidth.
    """
    try:
        user32 = ctypes.windll.user32
        user32.SetProcessDPIAware()
        dpi = int(user32.GetDpiForSystem())
        if dpi > 0:
            return dpi / 96.0
    except (AttributeError, OSError):
        pass
    return 1.0


def primary_screen() -> tuple[int, int]:
'@
S "shopee_sniper/fingerprint/env.py" $f $r

Write-Host ""
Write-Host "2/3 geometry in DIPs" -ForegroundColor Cyan

$f = @'
    w, h = screen
    return max(1280, min(1600, w - 80)), max(720, min(900, h - taskbar - 90))
'@
$r = @'
    w, h = screen
    # Floors drop for scaled displays: a 1280x720 DIP screen must still fit a
    # window with a visible frame.
    return max(1000, min(1600, w - 80)), max(640, min(900, h - taskbar - 90))
'@
S "shopee_sniper/fingerprint/env.py" $f $r

$f = @'
def identity(explicit: str = "") -> dict:
    path = find_chrome(explicit)
    version = version_of(path)
    screen = primary_screen()
    inner = window_for(screen)
    return {
        "chrome_path": path,
        "chrome_version": version,
        "ua": ua_for(version),
        "screen": screen,
        "inner": inner,
    }
'@
$r = @'
def identity(explicit: str = "") -> dict:
    path = find_chrome(explicit)
    version = version_of(path)
    scale = primary_scale()
    phys = primary_screen()
    # Publish DIPs, not physical pixels: these become screen.width and the
    # window size, both of which Chrome expresses in CSS px.
    screen = (max(1, round(phys[0] / scale)), max(1, round(phys[1] / scale)))
    inner = window_for(screen)
    return {
        "chrome_path": path,
        "chrome_version": version,
        "ua": ua_for(version),
        "screen": screen,
        "inner": inner,
        "dpr": scale,
    }
'@
S "shopee_sniper/fingerprint/env.py" $f $r

Write-Host ""
Write-Host "3/3 carry the real DPR" -ForegroundColor Cyan

$f = @'
        dpr=1.0,
'@
$r = @'
        dpr=ident["dpr"],
'@
S "shopee_sniper/fingerprint/profile.py" $f $r

Write-Host ""
Write-Host "check" -ForegroundColor Cyan
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
& python -m pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest regressed" }
& python -c "from shopee_sniper.fingerprint import env; i = env.identity(); print('screen', i['screen'], 'inner', i['inner'], 'dpr', i['dpr'])"

& python -m tools.fpcheck