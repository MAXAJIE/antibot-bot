# fix4.ps1 -- profile mints from the live binary, UA-CH left native, stale profiles cleared.

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
Write-Host "1/3 profile.py (mint from the live binary every load)" -ForegroundColor Cyan

W "shopee_sniper/fingerprint/profile.py" @'
"""Stable per-bot fingerprint, derived deterministically from a seed.

Two rules carry the parity:

  UA comes from the installed binary, not a constant. If the UA and the binary
  disagree, Sec-CH-UA and userAgentData disagree with the UA string and the
  contradiction is free to detect. Chrome auto-updates, so this is re-derived
  on every load rather than frozen into the profile.

  Screen geometry comes from the actual monitor. A profile claiming 2560x1440
  on a 1920x1080 panel makes window.screen and the viewport disagree, and
  Chrome silently clamps the window so outerWidth lies too.

Everything else stays seed-deterministic: mint() is a pure function of the seed
plus the live environment, so re-minting yields the same canvas seed, audio
seed, GPU and locale it always did.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from pathlib import Path

from . import env

LOCALES = [("en-MY", "Asia/Kuala_Lumpur"), ("en-SG", "Asia/Singapore"),
           ("id-ID", "Asia/Jakarta"), ("th-TH", "Asia/Bangkok"),
           ("en-PH", "Asia/Manila")]
GPUS = [
    ("Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)"),
    ("Google Inc. (Intel)",
     "ANGLE (Intel, Intel(R) UHD Graphics 630 Direct3D11 vs_5_0 ps_5_0, D3D11)"),
    ("Google Inc. (AMD)",
     "ANGLE (AMD, AMD Radeon RX 6600 Direct3D11 vs_5_0 ps_5_0, D3D11)"),
    ("Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce GTX 1650 Direct3D11 vs_5_0 ps_5_0, D3D11)"),
]


@dataclass(frozen=True)
class Profile:
    seed: str
    ua: str
    chrome_major: int
    chrome_version: str
    platform: str
    ch_platform: str
    width: int
    height: int
    screen_w: int
    screen_h: int
    dpr: float
    locale: str
    timezone: str
    gpu_vendor: str
    gpu_renderer: str
    hardware_concurrency: int
    device_memory: int
    canvas_seed: int
    audio_seed: int
    languages: tuple[str, ...]
    touch_points: int = 0
    taskbar_px: int = 48

    def as_dict(self) -> dict:
        d = asdict(self)
        d["languages"] = list(self.languages)
        return d

    @property
    def accept_language(self) -> str:
        head = self.languages[0]
        rest = [f"{l};q={round(1.0 - 0.1 * (i + 1), 1)}"
                for i, l in enumerate(self.languages[1:])]
        return ", ".join([head] + rest)

    @property
    def avail_height(self) -> int:
        return self.screen_h - self.taskbar_px

    def brands(self) -> list[list[str]]:
        return [[b, v] for b, v in env.brands_for(self.chrome_version)]

    def full_versions(self) -> list[list[str]]:
        return [[b, v] for b, v in env.full_version_list(self.chrome_version)]

    def stealth_cfg(self, native_ua: bool = True) -> dict:
        """Exactly what the document-start script is allowed to know.

        With a native UA the client hints are left alone: Chrome emits its own
        brand list and its own GREASE pair, and a hand-maintained copy drifts
        out of date the moment Google rotates the values.
        """
        cfg = {
            "platform": self.platform,
            "cores": self.hardware_concurrency,
            "memory": self.device_memory,
            "languages": list(self.languages),
            "touchPoints": self.touch_points,
            "screen": {"width": self.screen_w, "height": self.screen_h,
                       "availHeight": self.avail_height},
            "dpr": self.dpr,
            "window": {"w": self.width, "h": self.height},
            "gpuVendor": self.gpu_vendor,
            "gpuRenderer": self.gpu_renderer,
            "canvasSeed": self.canvas_seed,
            "audioSeed": self.audio_seed,
            "timezone": self.timezone,
        }
        if not native_ua:
            cfg["uaBrands"] = self.brands()
            cfg["uaFullVersions"] = self.full_versions()
            cfg["uaMobile"] = False
            cfg["uaPlatform"] = self.ch_platform
        return cfg


def _pick(seed: str, salt: str, seq):
    h = hashlib.sha256(f"{seed}:{salt}".encode()).digest()
    return seq[int.from_bytes(h[:4], "big") % len(seq)]


def _int(seed: str, salt: str) -> int:
    return int.from_bytes(
        hashlib.sha256(f"{seed}:{salt}".encode()).digest()[:8], "big")


def mint(seed: str, explicit_binary: str = "") -> Profile:
    ident = env.identity(explicit_binary)
    sw, sh = ident["screen"]
    iw, ih = ident["inner"]
    loc, tz = _pick(seed, "locale", LOCALES)
    gv, gr = _pick(seed, "gpu", GPUS)
    return Profile(
        seed=seed, ua=ident["ua"],
        chrome_major=int(ident["chrome_version"].split(".")[0]),
        chrome_version=ident["chrome_version"],
        platform="Win32", ch_platform="Windows",
        width=iw, height=ih, screen_w=sw, screen_h=sh,
        dpr=1.0,
        locale=loc, timezone=tz, gpu_vendor=gv, gpu_renderer=gr,
        hardware_concurrency=_pick(seed, "cores", [4, 8, 12, 16]),
        device_memory=_pick(seed, "mem", [8, 16]),
        canvas_seed=_int(seed, "canvas") % (2 ** 31),
        audio_seed=_int(seed, "audio") % (2 ** 31),
        # Two entries, matching what Chrome derives from --lang. A third
        # duplicate "en" gives an Accept-Language no real browser sends.
        languages=(loc, loc.split("-")[0]),
    )


def load_or_mint(path: str | Path, seed: str, explicit_binary: str = "",
                 refresh_geometry: bool = True) -> Profile:
    """Re-mint on every load and persist.

    The previous version kept a stored UA forever, so a Chrome update silently
    produced a profile claiming one version over a binary running another.
    mint() is deterministic on the seed, so nothing that should stay stable
    moves; only the environment-derived fields refresh.
    """
    prof = mint(seed, explicit_binary)
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(prof.as_dict(), indent=2), encoding="utf-8")
    return prof


def context_args(prof: Profile, proxy: str | None = None,
                 native_ua: bool = True) -> dict:
    """No Sec-CH-UA in extra_http_headers.

    Chrome already emits the full client-hint set from the binary. Injecting a
    copy through extra_http_headers produces duplicate headers on the document
    request, and a duplicate Sec-CH-UA is a harder tell than a wrong one.
    """
    args: dict = {
        "viewport": {"width": prof.width, "height": prof.height},
        "device_scale_factor": prof.dpr,
        "locale": prof.locale,
        "timezone_id": prof.timezone,
        "is_mobile": False,
        "has_touch": False,
        "java_script_enabled": True,
        "color_scheme": "light",
        "reduced_motion": "no-preference",
    }
    if not native_ua:
        args["user_agent"] = prof.ua
    if proxy:
        args["proxy"] = {"server": proxy}
    return args


def launch_args(prof: Profile, position: tuple[int, int]) -> list[str]:
    return [
        f"--window-position={position[0]},{position[1]}",
        f"--window-size={prof.width},{prof.height}",
        f"--force-device-scale-factor={prof.dpr}",
        f"--lang={prof.locale}",
        "--disable-blink-features=AutomationControlled",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate,OptimizationHints,MediaRouter,"
        "CalculateNativeWinOcclusion,InterestFeedContentSuggestions",
        "--disable-component-update",
        "--metrics-recording-only",
        "--no-service-autorun",
        "--disable-sync",
    ]
'@

Write-Host ""
Write-Host "2/3 leave userAgentData alone under a native UA" -ForegroundColor Cyan

S "shopee_sniper/fingerprint/patches.js" 'if (C.uaBrands) {' 'if (C.uaBrands && C.uaBrands.length) {'

S "shopee_sniper/bot.py" 'cfg = json.dumps(self.prof.stealth_cfg())' 'cfg = json.dumps(self.prof.stealth_cfg(not self.bp.native_ua))'

S "tools/fpcheck.py" 'json.dumps(prof.stealth_cfg())' 'json.dumps(prof.stealth_cfg(not bp.native_ua))'

Write-Host ""
Write-Host "3/3 clear stale profiles" -ForegroundColor Cyan
Get-ChildItem (Join-Path $root 'profiles') -Filter '*.json' -ErrorAction SilentlyContinue |
  ForEach-Object { Remove-Item $_.FullName -Force; Write-Host "  - profiles/$($_.Name)" }
Get-ChildItem (Join-Path $root 'profiles') -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'bot*' } |
  ForEach-Object { Remove-Item $_.FullName -Recurse -Force; Write-Host "  - profiles/$($_.Name)/" }

Write-Host ""
& python -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('shopee_sniper', quiet=1) else 1)"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }
& python -m pytest -q
if ($LASTEXITCODE -ne 0) { throw "tests failed" }

Write-Host ""
Write-Host "now:" -ForegroundColor Green
Write-Host "  python -m tools.fpcheck --headers"