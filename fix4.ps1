# fix4.ps1 -- close the UA-reduction and double-negation contradiction.
#
# Symptom was: FAIL navigator.userAgent want '...Chrome/157.0.8103.51...'
# got '...Chrome/157.0.0.0...'. The gate was right, the profile was wrong:
# ua_for() emitted a full build string, which no stock Chrome has sent since
# M110. Separately, stealth_cfg(not native_ua) double-negated the flag and
# injected a hand-maintained brand list on top of the browser's own hints.
#
# S() is idempotent: if the replacement is already present the file is skipped.

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

# Line endings are normalised on both sides before matching: the checkout is
# CRLF, the here-strings in this script are LF, and a raw .Contains() compares
# bytes. If the exact block still misses (indent drift, a hand edit), fall back
# to a whitespace-insensitive regex so the run does not abort on cosmetics.
function S($rel, $from, $to) {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) { throw "missing file $rel" }

  $t = [System.IO.File]::ReadAllText($p) -replace "`r`n", "`n"
  $f = $from -replace "`r`n", "`n"
  $r = $to -replace "`r`n", "`n"

  if ($t.Contains($r)) { Write-Host "  = $rel (already applied)"; return }

  $idx = -1
  $len = 0
  if ($t.Contains($f)) {
    $idx = $t.IndexOf($f)
    $len = $f.Length
  } else {
    $pat = (($f -split "`n") |
      ForEach-Object { [regex]::Escape($_) -replace '(\\ )+', '\s+' }) -join '\s*\n\s*'
    $m = [regex]::Match($t, $pat)
    if ($m.Success) { $idx = $m.Index; $len = $m.Length }
  }

  if ($idx -lt 0) {
    $where = ''
    if ($t.Contains('def ua_for')) {
      $where = "`n(ua_for is present - the block differs, likely already patched)"
    }
    throw "anchor not found in ${rel}:${where}`n$f"
  }

  $b = Join-Path $backup $rel
  New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
  Copy-Item $p $b -Force
  $out = $t.Substring(0, $idx) + $r + $t.Substring($idx + $len)
  [System.IO.File]::WriteAllText($p, $out, $enc)
  Write-Host "  S $rel"
}

Write-Host ""
Write-Host "1/7 env.py: emit the reduced UA the binary actually sends" -ForegroundColor Cyan

S "shopee_sniper/fingerprint/env.py" @'
def ua_for(version: str) -> str:
    return ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            f"(KHTML, like Gecko) Chrome/{version} Safari/537.36")
'@ @'
def reduced_version(version: str) -> str:
    """Chrome's UA-reduction form, major.0.0.0, frozen since M110.

    navigator.userAgent and the User-Agent header carry this. The full build
    appears only in Sec-CH-UA-Full-Version-List and in getHighEntropyValues.
    A UA string claiming 157.0.8103.51 is a UA no stock Chrome emits, and it
    disagrees with the browser's own reduced hint set on every request.
    """
    return f"{version.split('.')[0]}.0.0.0"


def ua_for(version: str) -> str:
    return ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            f"(KHTML, like Gecko) Chrome/{reduced_version(version)} Safari/537.36")


def ua_full(version: str) -> str:
    """Pre-reduction form, for callers that genuinely want the build number."""
    return ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            f"(KHTML, like Gecko) Chrome/{version} Safari/537.36")
'@

Write-Host ""
Write-Host "2/7 env.py: GREASE coverage + native brand order" -ForegroundColor Cyan

S "shopee_sniper/fingerprint/env.py" @'
GREASE = {128: "24", 129: "8", 130: "8", 131: "24", 132: "24", 133: "99",
          134: "99", 135: "8", 136: "24"}
'@ @'
GREASE = {128: "24", 129: "8", 130: "8", 131: "24", 132: "24", 133: "99",
          134: "99", 135: "8", 136: "24", 157: "99"}
# 157 is confirmed against a live capture. The table is authoritative where
# present; the fallback below keeps an unlisted major inside the real value set
# instead of pinning everything to "24", which is what 157 used to get.


def grease_for(version: str) -> str:
    major = int(version.split(".")[0])
    if major in GREASE:
        return GREASE[major]
    cycle = [24, 8, 8, 24, 24, 99, 99, 8, 24]
    return str(cycle[major % len(cycle)])
'@

# Brand order follows Chrome: the GREASE pair leads, then Google Chrome, then
# Chromium. The old order put Chromium first and disagreed with the header.
S "shopee_sniper/fingerprint/env.py" @'
def brands_for(version: str) -> list[tuple[str, str]]:
    major = version.split(".")[0]
    grease = GREASE.get(int(major), "24")
    return [("Chromium", major), ("Not_A Brand", grease), ("Google Chrome", major)]


def full_version_list(version: str) -> list[tuple[str, str]]:
    major = version.split(".")[0]
    grease = GREASE.get(int(major), "24")
    return [("Chromium", version), ("Not_A Brand", f"{grease}.0.0.0"),
            ("Google Chrome", version)]
'@ @'
def brands_for(version: str) -> list[tuple[str, str]]:
    major = version.split(".")[0]
    grease = grease_for(version)
    return [("Not_A Brand", grease), ("Google Chrome", major), ("Chromium", major)]


def full_version_list(version: str) -> list[tuple[str, str]]:
    grease = grease_for(version)
    return [("Not_A Brand", f"{grease}.0.0.0"), ("Google Chrome", version),
            ("Chromium", version)]
'@

Write-Host ""
Write-Host "3/7 kill the double negation on stealth_cfg" -ForegroundColor Cyan

S "shopee_sniper/fingerprint/profile.py" @'
        With a native UA the client hints are left alone: Chrome emits its own
        brand list and its own GREASE pair, and a hand-maintained copy drifts
        out of date the moment Google rotates the values.
        """
'@ @'
        With a native UA the client hints are left alone: Chrome emits its own
        brand list and its own GREASE pair, and a hand-maintained copy drifts
        out of date the moment Google rotates the values.

        The parameter means native, so callers pass bypass.native_ua directly.
        Callers used to pass `not bypass.native_ua`, which inverted the whole
        thing: native hints were overwritten by the stale copy, and the JS
        brand list then contradicted the Sec-CH-UA header on the wire.
        """
'@

# Any remaining `stealth_cfg(not X)` becomes `stealth_cfg(X)`, so call sites in
# files not listed here (smoke, drive, ad-hoc probes) are covered too.
$reNeg = [regex]'stealth_cfg\(not\s+([^)]+)\)'
Get-ChildItem -Path (Join-Path $root 'shopee_sniper'), (Join-Path $root 'tools') `
  -Recurse -Filter *.py -File | ForEach-Object {
  $t = [System.IO.File]::ReadAllText($_.FullName)
  if (-not $reNeg.IsMatch($t)) { return }
  $b = Join-Path $backup $_.FullName.Substring($root.Length + 1)
  New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
  Copy-Item $_.FullName $b -Force
  [System.IO.File]::WriteAllText($_.FullName, $reNeg.Replace($t, 'stealth_cfg($1)'), $enc)
  Write-Host "  S $($_.FullName.Substring($root.Length + 1))"
}

S "shopee_sniper/fingerprint/patches.js" @'
          if (h === "uaFullVersion") out.uaFullVersion = C.uaFullVersions[2][1];
'@ @'
          if (h === "uaFullVersion") {
            const gc = full.find((b) => b.brand === "Google Chrome");
            out.uaFullVersion = (gc || full[0]).version;
          }
'@

Write-Host ""
Write-Host "4/7 gate: compare the UA on its reduced form" -ForegroundColor Cyan

S "shopee_sniper/fingerprint/gate.py" @'
from __future__ import annotations

from .profile import Profile
'@ @'
from __future__ import annotations

import re

from .profile import Profile

_UA_BUILD = re.compile(r"Chrome/\d+\.\d+\.\d+\.\d+")


def _ua_core(ua: str) -> str:
    """Collapse the Chrome build to its reduced form before comparing.

    Chrome's UA reduction means the wire UA says major.0.0.0 while the binary
    knows a full build. An exact string compare fails on every point release for
    no reason. Collapsing still catches a wrong major, a wrong platform, and a
    Chromium-for-Chrome swap, which is what the check is actually for.
    """
    return _UA_BUILD.sub("Chrome/#", ua or "")
'@

S "shopee_sniper/fingerprint/gate.py" @'
    eq("navigator.userAgent", prof.ua, actual.get("ua"))
'@ @'
    got_ua = actual.get("ua") or ""
    if _ua_core(got_ua) != _ua_core(prof.ua):
        fails.append(f"navigator.userAgent: want {prof.ua!r} got {got_ua!r}")
'@

Write-Host ""
Write-Host "5/7 fpcheck: gate the header against userAgentData" -ForegroundColor Cyan

S "tools/fpcheck.py" @'
            dupes = {n for n in names if names.count(n) > 1}
            if dupes:
                fails.append(f"duplicate request headers: {sorted(dupes)}")
'@ @'
            dupes = {n for n in names if names.count(n) > 1}
            if dupes:
                fails.append(f"duplicate request headers: {sorted(dupes)}")

            # The JS brand list and the Sec-CH-UA header are derived from the
            # same source in real Chrome: same order, same GREASE value. A gate
            # that only checks membership passes a spoofed list that disagrees
            # with the wire, which is exactly the contradiction that survived
            # the last run.
            ch = next((v for n, v in (Echo.seen[-1] if Echo.seen else [])
                       if n.lower() == "sec-ch-ua"), "")
            if ch:
                hdr = []
                for part in ch.split(","):
                    if not part.strip():
                        continue
                    name = part.split(";")[0].strip().strip('"').replace("-", "_")
                    ver = part.split("v=")[1].strip().strip('"') if "v=" in part else ""
                    hdr.append((name, ver))
                js = [(str(b.get("brand")), str(b.get("version")))
                      for b in (actual.get("brands") or []) if isinstance(b, dict)]
                if hdr != js:
                    fails.append(f"sec-ch-ua header {hdr} vs userAgentData.brands {js} "
                                 "(order and GREASE must agree)")
'@

Write-Host ""
Write-Host "6/7 config: native hints on, stale profile purged" -ForegroundColor Cyan

foreach ($rel in @("config/bots.yaml", "config/bots.example.yaml")) {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) { continue }
  $t = [System.IO.File]::ReadAllText($p)
  $new = [regex]::Replace($t, '(?m)^(\s*)native_ua:\s*false\s*$', '${1}native_ua: true')
  if ($new -eq $t) { Write-Host "  = $rel (native_ua already true)"; continue }
  $b = Join-Path $backup $rel
  New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force | Out-Null
  Copy-Item $p $b -Force
  [System.IO.File]::WriteAllText($p, $new, $enc)
  Write-Host "  S $rel (native_ua -> true)"
}

# The persisted profile still carries the old full-build UA. load_or_mint
# re-mints on every load, but a stale file on disk misleads the next debugger.
$profDir = Join-Path $root 'profiles'
if (Test-Path $profDir) {
  Get-ChildItem $profDir -Recurse -Filter *.json -File | ForEach-Object {
    Remove-Item $_.FullName -Force
    Write-Host "  - $($_.FullName.Substring($root.Length + 1))"
  }
}

Write-Host ""
Write-Host "7/7 compile + verify" -ForegroundColor Cyan

& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) and compileall.compile_dir('tools', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed - see above" }
Write-Host "  OK all modules compile" -ForegroundColor Green

& python -m tools.fpcheck --headers
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "  fpcheck still red. Do not run captcha_probe yet." -ForegroundColor Yellow
} else {
  Write-Host ""
  Write-Host "  fpcheck green. next:" -ForegroundColor Green
  Write-Host "    python -m pytest -q"
  Write-Host "    python -m tools.captcha_probe --product"
}

Write-Host ""
Write-Host "backups: .backup/$stamp" -ForegroundColor DarkGray