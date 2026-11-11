"""Phase 8 OTP retrieval over pre-authorised IMAP.

imaplib is blocking, so the poll runs in a worker thread. Only UNSEEN mail from
the configured sender is read, newest first, and it is marked seen so a retry
cannot pick the same code.
"""
from __future__ import annotations

import asyncio
import email
import imaplib
import re
import time

from playwright.async_api import Page

from ..settings import OtpCfg

CODE_RE = re.compile(r"(?<!\d)(\d{6})(?!\d)")


class OtpTimeout(RuntimeError):
    pass


def _fetch(cfg: OtpCfg) -> str | None:
    box = imaplib.IMAP4_SSL(cfg.host, cfg.port)
    try:
        box.login(cfg.user, cfg.password)
        box.select("INBOX")
        typ, data = box.search(None, "UNSEEN", "FROM", cfg.sender)
        if typ != "OK" or not data or not data[0]:
            return None
        for num in reversed(data[0].split()[-5:]):
            typ, raw = box.fetch(num, "(RFC822)")
            if typ != "OK" or not raw or not raw[0]:
                continue
            msg = email.message_from_bytes(raw[0][1])
            body = ""
            if msg.is_multipart():
                for part in msg.walk():
                    if part.get_content_type() == "text/plain":
                        body = part.get_payload(decode=True).decode(errors="ignore")
                        break
            else:
                body = (msg.get_payload(decode=True) or b"").decode(errors="ignore")
            m = CODE_RE.search(body) or CODE_RE.search(msg.get("Subject", ""))
            if m:
                box.store(num, "+FLAGS", "\\Seen")
                return m.group(1)
        return None
    finally:
        try:
            box.logout()
        except Exception:
            pass


async def wait_code(cfg: OtpCfg, timeout_s: float | None = None) -> str:
    deadline = time.monotonic() + (timeout_s if timeout_s is not None else cfg.timeout_s)
    while time.monotonic() < deadline:
        code = await asyncio.to_thread(_fetch, cfg)
        if code:
            return code
        await asyncio.sleep(3)
    raise OtpTimeout(f"no OTP within {cfg.timeout_s:.0f}s")


async def submit(page: Page, code: str) -> None:
    """Fill every visible single-char box, then the confirm control."""
    await page.evaluate("""(code) => {
      const boxes = [...document.querySelectorAll('input[maxlength="1"]')];
      if (boxes.length === code.length) {
        boxes.forEach((b, i) => {
          b.focus();
          b.value = code[i];
          b.dispatchEvent(new Event('input', {bubbles: true}));
        });
      } else {
        const one = document.querySelector('input[type="text"], input[type="tel"]');
        if (one) {
          one.focus();
          one.value = code;
          one.dispatchEvent(new Event('input', {bubbles: true}));
        }
      }
    }""", code)
    btn = page.locator('button[class*="confirm"], button[class*="submit"]').first
    if await btn.count():
        await btn.click()