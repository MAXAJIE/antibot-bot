"""Stable per-bot fingerprint, derived deterministically from a seed.

Once SPC_F has been minted from a profile the profile is immutable - mutating
UA or viewport after that desyncs cookie from fingerprint.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from pathlib import Path

CHROME_MAJOR = 131

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      f"(KHTML, like Gecko) Chrome/{CHROME_MAJOR}.0.0.0 Safari/537.36")

SCREENS = [(1920, 1080), (2560, 1440), (1536, 864), (1680, 1050)]
LOCALES = [("en-SG", "Asia/Singapore"), ("en-MY", "Asia/Kuala_Lumpur"),
           ("id-ID", "Asia/Jakarta"), ("th-TH", "Asia/Bangkok")]
GPUS = [
    ("Google Inc. (NVIDIA)", "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)"),
    ("Google Inc. (Intel)", "ANGLE (Intel, Intel(R) UHD Graphics 630 Direct3D11 vs_5_0 ps_5_0, D3D11)"),
    ("Google Inc. (AMD)", "ANGLE (AMD, AMD Radeon RX 6600 Direct3D11 vs_5_0 ps_5_0, D3D11)"),
]


@dataclass(frozen=True)
class Profile:
    seed: str
    ua: str
    chrome_major: int
    platform: str
    width: int
    height: int
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

    def as_dict(self) -> dict:
        d = asdict(self)
        d["languages"] = list(self.languages)
        return d

    def sec_ch_ua(self) -> str:
        m = self.chrome_major
        return (f'"Google Chrome";v="{m}", "Chromium";v="{m}", '
                f'"Not_A Brand";v="24"')


def _pick(seed: str, salt: str, seq):
    h = hashlib.sha256(f"{seed}:{salt}".encode()).digest()
    return seq[int.from_bytes(h[:4], "big") % len(seq)]


def _int(seed: str, salt: str) -> int:
    return int.from_bytes(hashlib.sha256(f"{seed}:{salt}".encode()).digest()[:8], "big")


def mint(seed: str) -> Profile:
    w, h = _pick(seed, "screen", SCREENS)
    loc, tz = _pick(seed, "locale", LOCALES)
    gv, gr = _pick(seed, "gpu", GPUS)
    return Profile(
        seed=seed, ua=UA, chrome_major=CHROME_MAJOR, platform="Win32",
        width=w, height=h, dpr=1.0 if w >= 1920 else 1.25,
        locale=loc, timezone=tz, gpu_vendor=gv, gpu_renderer=gr,
        hardware_concurrency=_pick(seed, "cores", [4, 8, 12, 16]),
        device_memory=_pick(seed, "mem", [8, 16]),
        canvas_seed=_int(seed, "canvas") % (2**31),
        audio_seed=_int(seed, "audio") % (2**31),
        languages=(loc, loc.split("-")[0]),
    )


def load_or_mint(path: str | Path, seed: str) -> Profile:
    p = Path(path)
    if p.exists():
        d = json.loads(p.read_text())
        d["languages"] = tuple(d["languages"])
        return Profile(**d)
    prof = mint(seed)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(prof.as_dict(), indent=2))
    return prof


def context_args(prof: Profile, proxy: str | None = None) -> dict:
    args: dict = {
        "user_agent": prof.ua,
        "viewport": {"width": prof.width, "height": prof.height},
        "device_scale_factor": prof.dpr,
        "locale": prof.locale,
        "timezone_id": prof.timezone,
        "is_mobile": False,
        "has_touch": False,
        "java_script_enabled": True,
        "extra_http_headers": {
            "sec-ch-ua": prof.sec_ch_ua(),
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": f'"{prof.platform}"',
        },
    }
    if proxy:
        args["proxy"] = {"server": proxy}
    return args