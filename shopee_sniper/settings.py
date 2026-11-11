"""Optional config sections.

config.py stays strict about the required schema; everything added in phases 6-9
is optional and defaulted here, so an existing bots.yaml keeps loading.

Every section has from_dict() so a future frontend can POST a dict instead of
writing YAML.
"""
from __future__ import annotations

import enum
from dataclasses import dataclass, field
from pathlib import Path

import yaml


class Mode(enum.Enum):
    """test walks to place_order and aborts. real places."""

    TEST = "test"
    REAL = "real"


@dataclass(frozen=True)
class UiCfg:
    enabled: bool = True
    host: str = "127.0.0.1"
    port: int = 8732


@dataclass(frozen=True)
class CaptchaCfg:
    enabled: bool = True
    score_min: float = 0.35
    retry_shift_px: int = 4
    settle_ms: int = 60


@dataclass(frozen=True)
class OtpCfg:
    enabled: bool = False
    host: str = ""
    port: int = 993
    user: str = ""
    password: str = ""
    sender: str = ""
    timeout_s: float = 90.0


@dataclass(frozen=True)
class DriveCfg:
    """What to buy and how to recognise it.

    variant is the spec text joined with '|', e.g. "Size: M|Black".
    address_label and payment_method are matched as visible text.
    """

    mode: Mode = Mode.TEST
    product_url: str = ""
    variant: str = ""
    quantity: int = 1
    expected_price: float = 0.0
    price_tolerance: float = 0.02
    payment_method: str = ""
    address_label: str = ""
    selectors_path: str = ""
    keep_open: bool = False
    step_timeout_ms: int = 6000

    @classmethod
    def from_dict(cls, d: dict) -> "DriveCfg":
        base = cls()
        return cls(
            mode=Mode(str(d.get("mode", base.mode.value)).lower()),
            product_url=str(d.get("product_url", "")),
            variant=str(d.get("variant", "")),
            quantity=int(d.get("quantity", 1)),
            expected_price=float(d.get("expected_price", 0.0)),
            price_tolerance=float(d.get("price_tolerance", 0.02)),
            payment_method=str(d.get("payment_method", "")),
            address_label=str(d.get("address_label", "")),
            selectors_path=str(d.get("selectors_path", "")),
            keep_open=bool(d.get("keep_open", False)),
            step_timeout_ms=int(d.get("step_timeout_ms", 6000)),
        )


@dataclass(frozen=True)
class Extras:
    ui: UiCfg = field(default_factory=UiCfg)
    captcha: CaptchaCfg = field(default_factory=CaptchaCfg)
    otp: OtpCfg = field(default_factory=OtpCfg)
    drive: DriveCfg = field(default_factory=DriveCfg)


def load_dict(raw: dict) -> Extras:
    ui = raw.get("ui") or {}
    cap = raw.get("captcha") or {}
    otp = raw.get("otp") or {}
    drv = raw.get("drive") or {}
    return Extras(
        ui=UiCfg(bool(ui.get("enabled", True)), str(ui.get("host", "127.0.0.1")),
                 int(ui.get("port", 8732))),
        captcha=CaptchaCfg(bool(cap.get("enabled", True)),
                           float(cap.get("score_min", 0.35)),
                           int(cap.get("retry_shift_px", 4)),
                           int(cap.get("settle_ms", 60))),
        otp=OtpCfg(bool(otp.get("enabled", False)), str(otp.get("host", "")),
                   int(otp.get("port", 993)), str(otp.get("user", "")),
                   str(otp.get("password", "")), str(otp.get("sender", "")),
                   float(otp.get("timeout_s", 90.0))),
        drive=DriveCfg.from_dict(drv),
    )


def load(path: str | Path) -> Extras:
    return load_dict(yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {})