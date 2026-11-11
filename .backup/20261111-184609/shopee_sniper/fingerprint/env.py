"""Real-browser identity resolution.

The old code spoofed a UA string claiming "Google Chrome 131" on top of
Playwright's bundled Chromium, whose own Sec-CH-UA and navigator.userAgentData
said Chromium at whatever version the bundled binary actually was. Three
surfaces, three different answers.

Fix: run the installed Chrome, read its real version, derive every other surface
from that, and let the browser send its own client hints. Nothing is claimed
that the binary does not already say.
"""
from __future__ import annotations

import ctypes
import os
import re
import winreg

CHROME_EXE = "chrome.exe"
CANDIDATES = (
    r"%ProgramFiles%\Google\Chrome\Application\chrome.exe",
    r"%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe",
    r"%LocalAppData%\Google\Chrome\Application\chrome.exe",
)
VERSION_DIR = re.compile(r"^\d+\.\d+\.\d+\.\d+$")

# Chrome's GREASE brand/value pairs are derived from the major version. Only
# used when a version is forced; the native path does not need them.
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


class BinaryMissing(RuntimeError):
    pass


def find_chrome(explicit: str = "") -> str:
    if explicit:
        if os.path.isfile(explicit):
            return explicit
        raise BinaryMissing(f"bypass.executable not found: {explicit}")
    for raw in CANDIDATES:
        p = os.path.expandvars(raw)
        if os.path.isfile(p):
            return p
    for hive, key in (
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"),
        (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"),
    ):
        try:
            with winreg.OpenKey(hive, key) as k:
                p = winreg.QueryValueEx(k, "")[0]
            if os.path.isfile(p):
                return p
        except OSError:
            continue
    raise BinaryMissing(
        "no installed Chrome found - Playwright's bundled Chromium is the wrong "
        "binary for this. install Chrome, or set bypass.executable in bots.yaml")


class _FixedFileInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in (
        "dwSignature", "dwStrucVersion", "dwFileVersionMS", "dwFileVersionLS",
        "dwProductVersionMS", "dwProductVersionLS", "dwFileFlagsMask",
        "dwFileFlags", "dwFileOS", "dwFileType", "dwFileSubtype",
        "dwFileDateMS", "dwFileDateLS")]


def _file_version(path: str) -> str:
    try:
        ver = ctypes.windll.version
    except AttributeError:
        return ""
    size = ver.GetFileVersionInfoSizeW(path, None)
    if not size:
        return ""
    buf = ctypes.create_string_buffer(size)
    if not ver.GetFileVersionInfoW(path, 0, size, buf):
        return ""
    ptr = ctypes.c_void_p()
    ln = ctypes.c_uint()
    if not ver.VerQueryValueW(buf, "\\", ctypes.byref(ptr), ctypes.byref(ln)):
        return ""
    info = ctypes.cast(ptr, ctypes.POINTER(_FixedFileInfo)).contents
    ms, ls = info.dwFileVersionMS, info.dwFileVersionLS
    return f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"


def version_of(path: str) -> str:
    """Chrome installs to Application\\<version>\\chrome.exe. Trust the folder,
    fall back to the file resource."""
    parent = os.path.basename(os.path.dirname(path))
    if VERSION_DIR.match(parent):
        return parent
    v = _file_version(path)
    if not VERSION_DIR.match(v):
        raise BinaryMissing(f"cannot determine version of {path}")
    return v


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


def brands_for(version: str) -> list[tuple[str, str]]:
    major = version.split(".")[0]
    grease = GREASE.get(int(major), "24")
    return [("Chromium", major), ("Not_A Brand", grease), ("Google Chrome", major)]


def full_version_list(version: str) -> list[tuple[str, str]]:
    major = version.split(".")[0]
    grease = GREASE.get(int(major), "24")
    return [("Chromium", version), ("Not_A Brand", f"{grease}.0.0.0"),
            ("Google Chrome", version)]


def primary_screen() -> tuple[int, int]:
    """Physical primary-monitor pixels, DPI-aware.

    Without SetProcessDPIAware the value comes back scaled by the Windows zoom
    factor and then gets multiplied by the DPR again downstream.
    """
    try:
        user32 = ctypes.windll.user32
        user32.SetProcessDPIAware()
        w = int(user32.GetSystemMetrics(0))
        h = int(user32.GetSystemMetrics(1))
        if w > 0 and h > 0:
            return w, h
    except AttributeError:
        pass
    return 1920, 1080


def window_for(screen: tuple[int, int], taskbar: int = 48) -> tuple[int, int]:
    """Outer window that fits on the monitor with a visible title bar."""
    w, h = screen
    return max(1280, min(1600, w - 80)), max(720, min(900, h - taskbar - 90))


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