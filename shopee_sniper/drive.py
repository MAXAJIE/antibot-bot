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
    "add_to_cart": ("Add to Cart", "Tambah ke Keranjang", "ThÃªm vÃ o giá»"),
    "checkout": ("Checkout", "Check Out", "Thanh toÃ¡n"),
    "place_order": ("Place Order", "Pay Now", "Äáº·t hÃ ng"),
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