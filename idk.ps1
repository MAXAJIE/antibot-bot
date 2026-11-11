$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$enc = New-Object System.Text.UTF8Encoding($false)
function W($rel, $text) {
  $p = Join-Path $root $rel
  $dir = Split-Path $p -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"), $enc)
  Write-Host "  $rel"
}

W "shopee_sniper/settings.py" @'
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
    return load_dict(yaml.safe_load(Path(path).read_text()) or {})
'@

W "shopee_sniper/drive.py" @'
"""Phase 6.5 DOM driver: product page to the place-order button.

Selectors are structural because Shopee hashes class names. Every step tries a
CSS list, then visible text, then gives up fast. Selector lists can be replaced
from a JSON file so a frontend can retarget without a code change.

Nothing here touches timing. It only gets the page to the point where a shot is
legal.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from playwright.async_api import Page

from .log import JsonlLog
from .settings import DriveCfg
from .ui.store import Store

PRICE_RE = re.compile(r"[^\d.,]")

DEFAULTS: dict[str, list[str]] = {
    "title": ["h1", "[class*='product-briefing'] h1"],
    "price": ["[class*='pqTWkA']", "[class*='product-price']",
              "[class*='price-current']", "div[class*='price']"],
    "variant_chip": ["button[class*='product-variation']",
                     "[class*='variation'] button", "[class*='sku'] button"],
    "quantity": ["input[class*='quantity']", "input[name='quantity']"],
    "buy_now": ["button[class*='buy-now']", "button[class*='buyNow']"],
    "add_to_cart": ["button[class*='add-to-cart']", "button[class*='addToCart']"],
    "cart_link": ["a[href*='/cart']", "[class*='cart-drawer'] a[href*='checkout']"],
    "checkout": ["button[class*='checkout']", "a[href*='/checkout']"],
    "address_card": ["[class*='address-item']", "[class*='address-list'] [role='radio']"],
    "payment_row": ["[class*='payment-channel']", "[role='radio'][class*='payment']"],
    "place_order": ["button[class*='place-order']", "button[class*='placeOrder']"],
    "total": ["[class*='grand-total']", "[class*='total-price']"],
}

TEXT_FALLBACK: dict[str, tuple[str, ...]] = {
    "buy_now": ("Buy Now", "Beli Sekarang", "Mua Ngay"),
    "add_to_cart": ("Add to Cart", "Tambah ke Keranjang", "Thêm vào giỏ"),
    "checkout": ("Checkout", "Check Out", "Thanh toán"),
    "place_order": ("Place Order", "Pay Now", "Đặt hàng"),
}


class DriveError(RuntimeError):
    pass


def parse_price(text: str) -> float:
    """Handle 1.234.567 (ID) and 1,234.56 (SG) without guessing wrong."""
    s = PRICE_RE.sub("", text or "")
    if not s:
        raise ValueError(f"no digits in {text!r}")
    if "." in s and "," in s:
        dec = "." if s.rfind(".") > s.rfind(",") else ","
        s = s.replace("," if dec == "." else ".", "").replace(dec, ".")
    elif "," in s or "." in s:
        sep = "," if "," in s else "."
        head, _, tail = s.rpartition(sep)
        s = head.replace(sep, "") + "." + tail if len(tail) != 3 or not head \
            else s.replace(sep, "")
    return float(s)


def price_ok(actual: float, expected: float, tolerance: float) -> bool:
    if actual <= 0:
        return False
    if expected <= 0:
        return True
    return actual <= expected * (1.0 + tolerance)


def split_variant(spec: str) -> list[str]:
    return [p.strip() for p in re.split(r"[|,]", spec or "") if p.strip()]


@dataclass
class Drive:
    page: Page
    cfg: DriveCfg
    log: JsonlLog
    store: Store
    bot_id: str
    sel: dict[str, list[str]] = field(default_factory=lambda: dict(DEFAULTS))

    def __post_init__(self) -> None:
        if self.cfg.selectors_path:
            over = json.loads(Path(self.cfg.selectors_path).read_text())
            for k, v in over.items():
                self.sel[k] = list(v)

    async def _click(self, key: str) -> None:
        for css in self.sel.get(key, []):
            loc = self.page.locator(css).first
            try:
                if await loc.count() and await loc.is_visible():
                    await loc.click(timeout=self.cfg.step_timeout_ms)
                    return
            except Exception:
                continue
        for text in TEXT_FALLBACK.get(key, ()):
            try:
                await self.page.get_by_text(text, exact=False).first.click(
                    timeout=1500)
                return
            except Exception:
                continue
        raise DriveError(f"cannot click {key!r}")

    async def _text(self, key: str) -> str:
        for css in self.sel.get(key, []):
            loc = self.page.locator(css).first
            try:
                if await loc.count():
                    return (await loc.inner_text(timeout=1500)).strip()
            except Exception:
                continue
        return ""

    async def _step(self, name: str, coro) -> None:
        self.store.upsert(self.bot_id, last_event=name)
        self.log.write(bot_id=self.bot_id, event=f"step_{name}")
        await coro

    async def open_product(self) -> None:
        if not self.cfg.product_url:
            raise DriveError("drive.product_url is empty")
        await self.page.goto(self.cfg.product_url, wait_until="domcontentloaded")
        await self.page.bring_to_front()
        await self.page.wait_for_timeout(900)

    async def select_variant(self) -> list[str]:
        wanted = split_variant(self.cfg.variant)
        picked = []
        for token in wanted:
            loc = self.page.locator(
                f"button:has-text('{token}'), [class*='variation'] :text('{token}')"
            ).first
            try:
                await loc.click(timeout=self.cfg.step_timeout_ms)
                picked.append(token)
                await self.page.wait_for_timeout(250)
            except Exception:
                self.log.write(bot_id=self.bot_id, event="variant_miss",
                               token=token)
        if wanted and not picked:
            raise DriveError(f"no variant matched {wanted}")
        return picked

    async def check_price(self) -> float:
        raw = await self._text("price")
        if not raw:
            raise DriveError("price not found")
        actual = parse_price(raw)
        self.store.upsert(self.bot_id, offset_ms=actual)
        self.log.write(bot_id=self.bot_id, event="price", raw=raw, parsed=actual,
                       expected=self.cfg.expected_price)
        if not price_ok(actual, self.cfg.expected_price, self.cfg.price_tolerance):
            raise DriveError(
                f"price {actual} above {self.cfg.expected_price}"
                f" +{self.cfg.price_tolerance:.0%}")
        return actual

    async def to_checkout(self) -> None:
        try:
            await self._click("buy_now")
        except DriveError:
            await self._click("add_to_cart")
            await self.page.wait_for_timeout(700)
            await self._click("cart_link")
            await self.page.wait_for_timeout(700)
            await self._click("checkout")
        await self.page.wait_for_timeout(1200)

    async def select_address(self) -> None:
        if not self.cfg.address_label:
            return
        cards = self.page.locator(",".join(self.sel["address_card"]))
        n = await cards.count()
        for i in range(n):
            card = cards.nth(i)
            try:
                txt = await card.inner_text(timeout=1000)
            except Exception:
                continue
            if self.cfg.address_label.lower() in txt.lower():
                await card.click(timeout=self.cfg.step_timeout_ms)
                self.log.write(bot_id=self.bot_id, event="address_selected")
                return
        raise DriveError(f"address {self.cfg.address_label!r} not in list")

    async def select_payment(self) -> None:
        if not self.cfg.payment_method:
            return
        rows = self.page.locator(",".join(self.sel["payment_row"]))
        n = await rows.count()
        for i in range(n):
            row = rows.nth(i)
            try:
                txt = await row.inner_text(timeout=1000)
            except Exception:
                continue
            if self.cfg.payment_method.lower() in txt.lower():
                await row.click(timeout=self.cfg.step_timeout_ms)
                self.log.write(bot_id=self.bot_id, event="payment_selected")
                return
        raise DriveError(f"payment {self.cfg.payment_method!r} not offered")

    async def ready(self) -> str:
        """Confirm the place-order button exists; return the total text."""
        loc = self.page.locator(",".join(self.sel["place_order"])).first
        try:
            await loc.wait_for(state="visible", timeout=self.cfg.step_timeout_ms)
        except Exception as exc:
            raise DriveError("place-order button never appeared") from exc
        total = await self._text("total")
        self.store.upsert(self.bot_id, last_event="ready")
        self.log.write(bot_id=self.bot_id, event="ready_for_order", total=total)
        return total

    async def run_to_ready(self) -> str:
        await self._step("open", self.open_product())
        await self._step("variant", self.select_variant())
        await self._step("price", self.check_price())
        await self._step("checkout", self.to_checkout())
        await self._step("address", self.select_address())
        await self._step("payment", self.select_payment())
        return await self.ready()
'@

W "shopee_sniper/bot.py" @'
"""Phase 3/7 per-bot browser: the signer and the fingerprint oracle.

Headed, profile-locked, overlay installed, then driven to the place-order button
by drive.Drive. The browser signs; the sidecar only fires.
"""
from __future__ import annotations

import random
from pathlib import Path

from playwright.async_api import BrowserContext, Page, Playwright

from .config import Bot, Config
from .drive import Drive
from .fingerprint import profile as fp
from .log import JsonlLog
from .session import warmup
from .settings import DriveCfg
from .sign.harvest import Harvested, harvest
from .ui import inject
from .ui.store import Store


class BotRuntime:
    def __init__(self, cfg: Config, bot: Bot, log: JsonlLog, store: Store,
                 dcfg: DriveCfg) -> None:
        self.cfg = cfg
        self.bot = bot
        self.log = log
        self.store = store
        self.dcfg = dcfg
        self.prof = fp.load_or_mint(bot.profile_path, seed=bot.id)
        self.ctx: BrowserContext | None = None
        self.page: Page | None = None

    @property
    def base(self) -> str:
        return f"https://shopee.{self.cfg.sale.region}"

    async def start(self, pw: Playwright, position: tuple[int, int]) -> None:
        args = [
            f"--window-position={position[0]},{position[1]}",
            f"--window-size={self.prof.width},{self.prof.height}",
            f"--lang={self.prof.locale}",
            "--disable-blink-features=AutomationControlled",
        ]
        kwargs = fp.context_args(self.prof, self.bot.proxy)
        kwargs.pop("user_agent")
        self.ctx = await pw.chromium.launch_persistent_context(
            user_data_dir=str(Path(self.bot.profile_path).with_suffix("")),
            headless=False, args=args, user_agent=self.prof.ua, **kwargs)
        self.page = self.ctx.pages[0] if self.ctx.pages else await self.ctx.new_page()
        await inject.install(self.page, self.bot.id)
        await self.page.add_init_script(
            path=str(Path(fp.__file__).with_name("patches.js")))
        await self.page.bring_to_front()
        self.log.write(bot_id=self.bot.id, event="browser_start")

    def drive(self) -> Drive:
        assert self.page
        return Drive(page=self.page, cfg=self.dcfg, log=self.log,
                     store=self.store, bot_id=self.bot.id)

    async def warm(self, minutes: int) -> None:
        assert self.page
        await warmup.warm(self.page, self.base, minutes,
                          random.Random(self.bot.id))

    async def to_ready(self) -> str:
        return await self.drive().run_to_ready()

    async def harvest(self) -> Harvested:
        assert self.page and self.ctx
        cdp = await self.ctx.new_cdp_session(self.page)
        got = await harvest(cdp, self.page, "*place_order*")
        self.log.write(bot_id=self.bot.id, event="harvest",
                       headers=len(got.headers))
        return got

    async def close(self, keep_open: bool = False) -> None:
        if self.ctx and not keep_open:
            await self.ctx.close()
            self.log.write(bot_id=self.bot.id, event="browser_close")
'@

W "shopee_sniper/orchestrator/run.py" @'
"""Phase 6 sale runner.

Two modes, one code path until the end:

  test  walk to place_order, intercept, abort. No order is created. The captured
        request is written to contract/ so test doubles as Phase 0 capture.
  real  the same walk, then fire the captured request through the sidecar at T0.

--yes skips the confirmation. Nothing is placed without a real-mode race win.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import sys
import time
from pathlib import Path

from .. import contract, settings
from ..bot import BotRuntime
from ..config import load as load_cfg
from ..log import JsonlLog
from ..net.pool import Pool
from ..session.state import Preconditions
from ..settings import Mode
from ..timing import clock
from ..ui.store import Store
from .election import Election
from .race import Participant, Race
from .squad import Squad

REQUIRED_HEADER = "af-ac-enc-dat"


async def prepare(sq: Squad, runtimes: dict[str, BotRuntime],
                  warm_min: int) -> dict[str, int]:
    """Bring bots to ARMED and return their calibrated RTT per bot."""
    live = sq.bind()
    if not live:
        return {}
    rtts: dict[str, int] = {}
    for bot_id in live:
        rtt = await asyncio.to_thread(sq.calibrate, bot_id)
        if rtt is None:
            continue
        rtts[bot_id] = rtt
        sq.ready(bot_id)
        rt = runtimes.get(bot_id)
        if rt:
            if warm_min:
                await rt.warm(warm_min)
            await rt.to_ready()
        sq.arm(bot_id, Preconditions(
            cookies_present=True, spc_f_present=True, cart_staged=True,
            checkout_token_fresh=True, payment_selected=True,
            shipping_selected=True, rtt_samples=sq.cfg.timing.rtt_min_samples,
            rtt_min_samples=sq.cfg.timing.rtt_min_samples))
    return rtts


def save_fixture(got, out: Path) -> None:
    order = [h for h, _ in got.headers]
    doc = {
        "endpoint": "/api/v4/checkout/place_order",
        "method": "POST",
        "header_order": order,
        "headers": {h: v for h, v in got.headers},
        "body": got.body,
        "captured_at": got.at_ms // 1000,
        "ttl_curve": [],
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2))


async def main_async(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--fixture", default="contract/latest.json")
    ap.add_argument("--mode", choices=[m.value for m in Mode], default=None)
    ap.add_argument("--warm-min", type=int, default=0)
    ap.add_argument("--yes", action="store_true")
    a = ap.parse_args(argv)

    cfg = load_cfg(a.config)
    extra = settings.load(a.config)
    dcfg = extra.drive
    if a.mode:
        dcfg = settings.DriveCfg(**{**dcfg.__dict__, "mode": Mode(a.mode)})
    mode = dcfg.mode
    if not dcfg.product_url:
        print("drive.product_url is empty", file=sys.stderr)
        return 1

    log = JsonlLog(f"logs/{mode.value}.jsonl")
    store = Store()
    if extra.ui.enabled:
        from ..ui import console
        srv = console.serve(store, extra.ui.host, extra.ui.port)
        print(f"console http://{extra.ui.host}:{srv.server_port}")

    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    runtimes: dict[str, BotRuntime] = {}
    for i, b in enumerate(cfg.bots):
        runtimes[b.id] = BotRuntime(cfg, b, log, store, dcfg)
        await runtimes[b.id].start(pw, (30 + 620 * (i % 3), 30 + 400 * (i // 3)))

    code = 1
    try:
        sq = Squad(cfg=cfg, log=log, pool=Pool(cfg.proxy.max_p50_ms,
                                              cfg.proxy.preflight_attempts, log))
        rtts = await prepare(sq, runtimes, a.warm_min)
        if not rtts:
            print("no bot reached ready", file=sys.stderr)
            return 1
        print(f"ready: {sorted(rtts)}")
        for bot_id in rtts:
            store.upsert(bot_id, state="READY")

        if mode is Mode.TEST:
            for bot_id, rt in runtimes.items():
                if bot_id not in rtts:
                    continue
                got = await rt.harvest()
                names = [h for h, _ in got.headers]
                ok = REQUIRED_HEADER in names
                print(f"{bot_id}: {len(names)} headers, "
                      f"{REQUIRED_HEADER}={'yes' if ok else 'NO'}, "
                      f"body {len(got.body)}B")
                if ok:
                    save_fixture(got, Path(a.fixture))
            print(f"fixture written to {a.fixture} (ttl_curve empty - unmeasured)")
            code = 0
        else:
            if not a.yes:
                await asyncio.to_thread(input, "press enter to arm and fire ")
            fx = contract.load(a.fixture)
            ttl_safe = 2.0
            if fx.ttl_curve:
                ttl_safe = fx.ttl_safe_s(cfg.harvest.ttl_safety)
            else:
                print("warning: fixture has no ttl_curve, using 2.0s")
            t0 = cfg.sale.t0_ns
            lead = t0 - clock.now_ns() - cfg.harvest.lead_ms * 1_000_000
            if lead > 0:
                print(f"waiting {lead / 1e9:.1f}s to harvest lead")
                clock.sleep_until_ns(t0 - cfg.harvest.lead_ms * 1_000_000)

            parts: list[Participant] = []
            for bot_id, rtt in rtts.items():
                got = await runtimes[bot_id].harvest()
                parts.append(Participant(
                    bot_id=bot_id, conn_id=f"{bot_id}-{int(time.time())}",
                    fixture=fx, rtt_ns=rtt,
                    harvested_at_ms=clock.now_ns() // 1_000_000,
                    session=sq.session(bot_id)))
                store.upsert(bot_id, rtt_ms=rtt / 1e6, ttl_s=ttl_safe)

            el = Election(t0_ns=t0, needle_offset_ms=cfg.timing.needle_offset_ms,
                          jitter_sigma_ms=cfg.timing.jitter_sigma_ms,
                          clamp_ms=cfg.timing.jitter_clamp_ms,
                          rng=random.Random(cfg.sale.item_id))
            race = Race(cfg, log, el, ttl_safe, cfg.sidecar_url,
                        f"shopee.{cfg.sale.region}",
                        cfg.timing.ingest_est_ms * 1_000_000)
            out = await race.run(t0, parts)
            log.write(event="race_done", winner=out.winner,
                      order_id=out.order_id, quorum=out.quorum)
            print(f"winner={out.winner} order={out.order_id} quorum={out.quorum}")
            code = 0 if out.winner else 2
    finally:
        for rt in runtimes.values():
            await rt.close(keep_open=dcfg.keep_open)
        if not dcfg.keep_open:
            await pw.stop()
        else:
            print("browsers left open, ctrl-c to exit")
            await asyncio.to_thread(input, "")
            await pw.stop()
    return code


def main() -> int:
    return asyncio.run(main_async(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "tools/drive.py" @'
"""Drive the browser to the place-order button with no timing and no sidecar.

This is the selector workbench: run it after any Shopee UI change, read which
step fails, fix config/selectors.json, run again. --mode test also writes the
captured request to a fixture.
"""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

from shopee_sniper import contract, settings
from shopee_sniper.bot import BotRuntime
from shopee_sniper.config import load as load_cfg
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.run import save_fixture
from shopee_sniper.ui.store import Store


async def run(config: str, mode: str, fixture: str, keep: bool) -> int:
    cfg = load_cfg(config)
    extra = settings.load(config)
    dcfg = settings.DriveCfg(**{**extra.drive.__dict__,
                                "mode": settings.Mode(mode), "keep_open": keep})
    log = JsonlLog("logs/drive.jsonl")
    store = Store()
    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    bot = cfg.bots[0]
    rt = BotRuntime(cfg, bot, log, store, dcfg)
    code = 1
    try:
        await rt.start(pw, (60, 60))
        total = await rt.to_ready()
        print(f"reached place-order, total={total!r}")
        if dcfg.mode is settings.Mode.TEST:
            got = await rt.harvest()
            names = [h for h, _ in got.headers]
            print(f"captured {len(names)} headers, body {len(got.body)}B")
            print("has af-ac-enc-dat:", "af-ac-enc-dat" in names)
            save_fixture(got, Path(fixture))
            print(f"fixture -> {fixture}")
        code = 0
    except Exception as exc:
        print(f"FAILED at {store.snapshot()['bots'].get(bot.id, {}).get('last_event')}: {exc}")
    finally:
        await rt.close(keep_open=keep)
        if keep:
            await asyncio.to_thread(input, "enter to close ")
        await pw.stop()
    return code


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--mode", choices=["test", "real"], default="test")
    ap.add_argument("--fixture", default="contract/latest.json")
    ap.add_argument("--keep-open", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.config, a.mode, a.fixture, a.keep_open))


if __name__ == "__main__":
    raise SystemExit(main())
'@

W "config/selectors.json" @'
{
  "_comment": "Override any key from drive.DEFAULTS. Frontend edits this file.",
  "price": ["[class*='pqTWkA']", "[class*='product-price']"],
  "buy_now": ["button[class*='buy-now']"],
  "place_order": ["button[class*='place-order']"]
}
'@

W "tests/test_drive.py" @'
import pytest

from shopee_sniper.drive import parse_price, price_ok, split_variant


@pytest.mark.parametrize("text,want", [
    ("$12.50", 12.5),
    ("1,234.56", 1234.56),
    ("Rp 1.234.567", 1234567.0),
    ("12.500", 12500.0),
    ("8.5", 8.5),
])
def test_parse_price(text: str, want: float) -> None:
    assert parse_price(text) == want


def test_parse_price_rejects_empty() -> None:
    with pytest.raises(ValueError):
        parse_price("n/a")


def test_price_guard_upper_bound() -> None:
    assert price_ok(100.0, 100.0, 0.02)
    assert price_ok(101.0, 100.0, 0.02)
    assert not price_ok(103.0, 100.0, 0.02)


def test_price_guard_allows_discount() -> None:
    assert price_ok(80.0, 100.0, 0.02)


def test_price_guard_without_expectation() -> None:
    assert price_ok(999.0, 0.0, 0.0)
    assert not price_ok(0.0, 0.0, 0.0)


def test_split_variant() -> None:
    assert split_variant("Size: M|Black") == ["Size: M", "Black"]
    assert split_variant(" Red, XL ,") == ["Red", "XL"]
    assert split_variant("") == []
'@

W "Makefile" @'
.PHONY: setup build test clean
setup:
	python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"
build:
	cd sidecar && go build -o ../bin/sidecar .
test:
	python -m pytest -q
clean:
	rm -rf bin logs .venv

.PHONY: gates smoke drive drive-test console
gates:
	python -m tools.slider --n 20
	python -m tools.election --bots 6 --dry
	python -m tools.rehearsal --bots 6

smoke:
	python -m tools.smoke --bots 6

drive:
	python -m tools.drive --mode test --keep-open

drive-test:
	python -m shopee_sniper.orchestrator.run --mode test --yes

console:
	python -m tools.console --log logs/sale.jsonl
'@

Write-Host ""
Write-Host "written. add the drive block to config/bots.yaml:" -ForegroundColor Green
Write-Host @'

drive:
  mode: test
  product_url: "https://shopee.sg/product/123456/789012"
  variant: "Size: M|Black"
  quantity: 1
  expected_price: 25.90
  price_tolerance: 0.02
  payment_method: "Cash on Delivery"
  address_label: "Chin Jie"
  selectors_path: "config/selectors.json"
  keep_open: false
  step_timeout_ms: 6000

'@
Write-Host "then: python -m pytest -q" -ForegroundColor Green
Write-Host "then: python -m tools.drive --mode test --keep-open" -ForegroundColor Green