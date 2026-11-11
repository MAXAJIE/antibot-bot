# fix7.ps1 -- config.Config is missing the bypass field.
#
# bypass.ps1 patched config.py in four steps and threw on the first anchor miss,
# leaving the import half-applied and the field, the loader read and the
# constructor arg absent. settings.py ran afterwards, so fpcheck's
# extra.bypass worked while cfg.bypass raised.
#
# Each piece is detected independently and only the missing ones are added.

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
if (-not (Test-Path (Join-Path $root 'shopee_sniper'))) { throw "run this from the repo root" }
$enc = New-Object System.Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $root ".backup/$stamp"
$rel = 'shopee_sniper/config.py'
$p = Join-Path $root $rel
$t = ([System.IO.File]::ReadAllText($p)) -replace "`r`n", "`n"

Write-Host ""
Write-Host "config.py as it stands" -ForegroundColor Cyan
$n = 0
foreach ($line in ($t -split "`n")) {
  $n++
  if ($line -match '^(from dataclasses|class Config|@dataclass)|^\s+(bots:|sidecar_url=|s, t, p, l, h|bypass)') {
    Write-Host ("  {0,4}: {1}" -f $n, $line)
  }
}
foreach ($piece in @('dataclass, field', 'class BypassCfg', 'bypass: BypassCfg', 'raw.get("bypass")', 'bypass=BypassCfg(')) {
  $state = if ($t.Contains($piece)) { 'present' } else { 'MISSING' }
  Write-Host ("  {0,-22} {1}" -f $piece, $state) -ForegroundColor $(if ($state -eq 'MISSING') { 'Yellow' } else { 'DarkGray' })
}
Write-Host ""

$orig = $t

# 1. field import
if (-not $t.Contains('dataclass, field') -and $t.Contains('from dataclasses import dataclass')) {
  $t = $t.Replace('from dataclasses import dataclass', 'from dataclasses import dataclass, field')
  Write-Host "  + import field"
}

# 2. BypassCfg must precede Config: default_factory resolves during the Config
#    class body, so a forward reference is a NameError.
if (-not $t.Contains('class BypassCfg')) {
  $blk = @'
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


'@
  $m = [regex]::Match($t, '(?m)^@dataclass\(frozen=True\)\nclass Config:')
  if (-not $m.Success) { throw "no '@dataclass(frozen=True)' + 'class Config:' pair found" }
  $t = $t.Insert($m.Index, $blk)
  Write-Host "  + BypassCfg class"
}

# 3. Config field, after the last field so it stays legal (defaults last)
if (-not $t.Contains('bypass: BypassCfg')) {
  $m = [regex]::Match($t, '(?m)^[ \t]*bots: tuple\[Bot, \.\.\.\][ \t]*$')
  if ($m.Success) { $at = $m.Index + $m.Length }
  else {
    $cm = [regex]::Match($t, '(?ms)^class Config:.*?(?=\nclass |\n@dataclass|\z)')
    if (-not $cm.Success) { throw "class Config body not found" }
    $fields = [regex]::Matches($cm.Value, '(?m)^[ \t]+[a-z_][a-z0-9_]*:[^\n]*$')
    if ($fields.Count -eq 0) { throw "Config has no fields to anchor after" }
    $at = $cm.Index + $fields[$fields.Count - 1].Index + $fields[$fields.Count - 1].Length
  }
  $t = $t.Insert($at, "`n    bypass: BypassCfg = field(default_factory=BypassCfg)")
  Write-Host "  + Config.bypass field"
}

# 4. loader read
if (-not $t.Contains('raw.get("bypass")')) {
  $m = [regex]::Match($t, '(?m)^[ \t]*s, t, p, l, h = \([^\)]*\)[ \t]*$')
  if (-not $m.Success) { throw "no 's, t, p, l, h = (...)' unpacking found" }
  $t = $t.Insert($m.Index + $m.Length, "`n    b = raw.get(`"bypass`") or {}")
  Write-Host "  + loader read"
}

# 5. constructor arg
if (-not $t.Contains('bypass=BypassCfg(')) {
  $m = [regex]::Match($t, '(?m)^[ \t]*sidecar_url=str\(raw\["sidecar"\]\["url"\]\),')
  if (-not $m.Success) { throw "no sidecar_url= construction line found" }
  $arg = @'
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
'@
  $t = $t.Insert($m.Index, $arg)
  Write-Host "  + constructor arg"
}

if ($t -ne $orig) {
  New-Item -ItemType Directory -Path (Split-Path (Join-Path $backup $rel) -Parent) -Force | Out-Null
  Copy-Item $p (Join-Path $backup $rel) -Force
  [System.IO.File]::WriteAllText($p, $t, $enc)
  Write-Host "  written (backup: .backup/$stamp)" -ForegroundColor DarkGray
} else {
  Write-Host "  nothing to change"
}

Write-Host ""
Write-Host "check" -ForegroundColor Cyan
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_file('shopee_sniper/config.py', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "config.py does not compile" }
& python -c "from shopee_sniper import config; c = config.load('config/bots.yaml'); print('bypass ok:', c.bypass.native_ua, c.bypass.hard_block_max)"
if ($LASTEXITCODE -ne 0) { throw "config.load still does not expose bypass" }

& python -m pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest regressed" }

& python -m tools.captcha_probe --product