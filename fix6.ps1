# fix6.ps1 -- fix the idempotency guard, then apply the real comparator fix.
#
# The previous run skipped step 1: S() treats "replacement already present" as
# applied, and the replacement was a prefix of the anchor, so .Contains()
# returned true on an unpatched file. Guard on the anchor's absence instead.

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
  # Applied means the anchor is gone and the result is in. Never infer it from
  # the replacement alone: a replacement can be a prefix of its own anchor.
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
Write-Host "1/2 keep the hyphen form on the header side" -ForegroundColor Cyan

S "tools/fpcheck.py" @'
                    name = part.split(";")[0].strip().strip('"').replace("-", "_")
'@ @'
                    name = part.split(";")[0].strip().strip('"')  # Chrome 157 uses hyphens on both surfaces
'@

Write-Host ""
Write-Host "2/2 verify" -ForegroundColor Cyan

& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('tools', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

& python -m tools.fpcheck --headers
$code = $LASTEXITCODE
Write-Host ""
if ($code -eq 0) {
  Write-Host "  fpcheck green. next:" -ForegroundColor Green
  Write-Host "    python -m pytest -q"
  Write-Host "    python -m tools.captcha_probe --product"
} else {
  Write-Host "  still red - paste the FAIL block only." -ForegroundColor Yellow
}
Write-Host "backups: .backup/$stamp" -ForegroundColor DarkGray