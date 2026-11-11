# fix8b.ps1 -- verify_fingerprint probed a non-secure context.
#
# navigator.userAgentData is secure-context gated. about:blank is an opaque
# origin, so the API is undefined there; fpcheck passed only because it used
# http://127.0.0.1. set_content also writes into the live document, so the
# document-start script never runs on it either.

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
Write-Host "1/3 probe reports the context" -ForegroundColor Cyan

$f1 = @'
      brands: (navigator.userAgentData && navigator.userAgentData.brands) || [],
'@
$r1 = @'
      secure: window.isSecureContext,
      brands: (navigator.userAgentData && navigator.userAgentData.brands) || [],
'@
S "shopee_sniper/fingerprint/probe.py" $f1 $r1

Write-Host ""
Write-Host "2/3 gate names the context, not the browser" -ForegroundColor Cyan

$f2 = @'
    eq("navigator.webdriver", False, actual.get("webdriver"),
       "must be false, not undefined")
'@
$r2 = @'
    eq("navigator.webdriver", False, actual.get("webdriver"),
       "must be false, not undefined")
    # userAgentData is secure-context gated: about:blank and data: documents
    # report it undefined. Say so, or the brands check below looks like a
    # spoofing bug when it is really a harness bug.
    if actual.get("secure") is False:
        fails.append("not a secure context: userAgentData is gated here, probe "
                     "over loopback or https")
'@
S "shopee_sniper/fingerprint/gate.py" $f2 $r2

Write-Host ""
Write-Host "3/3 probe over loopback in verify_fingerprint" -ForegroundColor Cyan

$f3 = @'
    async def verify_fingerprint(self) -> None:
        """Refuse to warm up on a contradictory browser."""
        assert self.page
        await self.page.goto("about:blank")
        await self.page.set_content("<html><body></body></html>")
        actual = await probe.dump(self.page)
        fails = gate.consistency(self.prof, actual)
'@
$r3 = @'
    async def verify_fingerprint(self) -> None:
        """Refuse to warm up on a contradictory browser.

        The probe needs a secure context. navigator.userAgentData is gated
        behind one, so about:blank returns it undefined and the brands check
        fails for the wrong reason; set_content also reuses the live document,
        so the document-start script never runs on it. Loopback is potentially
        trustworthy, and route() serves the document with no socket and no DNS.
        """
        assert self.page

        async def _blank(route):
            await route.fulfill(status=200, content_type="text/html",
                                body="<html><body></body></html>")

        url = "http://127.0.0.1/__fp__"
        await self.page.route(url, _blank)
        try:
            await self.page.goto(url, wait_until="load")
            actual = await probe.dump(self.page)
        finally:
            await self.page.unroute(url)
        fails = gate.consistency(self.prof, actual)
'@
S "shopee_sniper/bot.py" $f3 $r3

Write-Host ""
Write-Host "check" -ForegroundColor Cyan
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
& python -m pytest -q
if ($LASTEXITCODE -ne 0) { throw "pytest regressed" }

& python -m tools.captcha_probe --product