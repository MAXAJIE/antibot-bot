# fix5.ps1 -- header/brand comparator compared a munged name against a raw one.
#
#   FAIL sec-ch-ua header [('Not_A.Brand','99'),...] vs brands [('Not-A.Brand','99'),...]
#
# Chrome 157 emits the hyphen form on both surfaces. The check did
# .replace("-","_") on the header only, so it could never pass. Also adds a
# strict UA-reduction assert: gate.consistency now collapses the build, so a
# full-build UA would otherwise slip through unnoticed.

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
  if ($t.Contains($r)) { Write-Host "  = $rel (already applied)"; return }
  $idx = -1; $len = 0
  if ($t.Contains($f)) { $idx = $t.IndexOf($f); $len = $f.Length }
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
Write-Host "1/3 compare brand names raw" -ForegroundColor Cyan

S "tools/fpcheck.py" @'
                    name = part.split(";")[0].strip().strip('"').replace("-", "_")
'@ @'
                    name = part.split(";")[0].strip().strip('"')
'@

Write-Host ""
Write-Host "2/3 assert the UA is actually reduced" -ForegroundColor Cyan

S "tools/fpcheck.py" @'
import argparse
import asyncio
import json
import threading
'@ @'
import argparse
import asyncio
import json
import re
import threading

# gate.consistency collapses the Chrome build before comparing, so it tolerates
# both the reduced and the full form. Assert the reduced form explicitly: it is
# the only one a stock Chrome puts on the wire since M110.
_REDUCED_UA = re.compile(
    r"Mozilla/5\.0 \(Windows NT 10\.0; Win64; x64\) AppleWebKit/537\.36 "
    r"\(KHTML, like Gecko\) Chrome/\d+\.0\.0\.0 Safari/537\.36")
'@

S "tools/fpcheck.py" @'
        fails = gate.consistency(prof, actual)
        width = max(len(k) for k in actual)
'@ @'
        fails = gate.consistency(prof, actual)
        if not _REDUCED_UA.fullmatch(actual.get("ua") or ""):
            fails.append(f"navigator.userAgent is not UA-reduced: "
                         f"{actual.get('ua')!r} (want Chrome/<major>.0.0.0)")
        width = max(len(k) for k in actual)
'@

Write-Host ""
Write-Host "3/3 verify" -ForegroundColor Cyan

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
  Write-Host "  still red - paste the block." -ForegroundColor Yellow
}
Write-Host "backups: .backup/$stamp" -ForegroundColor DarkGray