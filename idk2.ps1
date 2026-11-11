$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$enc = New-Object System.Text.UTF8Encoding($false)
function W($rel, $text) {
  $p = Join-Path $root $rel
  [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"), $enc)
  Write-Host "  $rel"
}
function S($rel, $from, $to) {
  $p = Join-Path $root $rel
  $t = [System.IO.File]::ReadAllText($p)
  if (-not $t.Contains($from)) { throw "pattern not found in $rel" }
  [System.IO.File]::WriteAllText($p, $t.Replace($from, $to), $enc)
  Write-Host "  patched $rel"
}

S "shopee_sniper/config.py" 'raw = yaml.safe_load(Path(path).read_text())' 'raw = yaml.safe_load(Path(path).read_text(encoding="utf-8"))'
S "shopee_sniper/settings.py" 'return load_dict(yaml.safe_load(Path(path).read_text()) or {})' 'return load_dict(yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {})'
S "shopee_sniper/contract.py" 'raw = json.loads(Path(path).read_text())' 'raw = json.loads(Path(path).read_text(encoding="utf-8"))'
S "shopee_sniper/observe/metrics.py" 'for line in p.read_text().splitlines():' 'for line in p.read_text(encoding="utf-8", errors="replace").splitlines():'
S "tools/console.py" 'for line in p.read_text().splitlines():' 'for line in p.read_text(encoding="utf-8", errors="replace").splitlines():'

Write-Host ""
Write-Host "done. retry:" -ForegroundColor Green
Write-Host "  python -m tools.drive --mode test --keep-open"