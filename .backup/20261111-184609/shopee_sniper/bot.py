"""Phase 3/7 per-bot browser: the signer and the fingerprint oracle.

Headed persistent context on the installed Chrome, identity-locked, stealth
installed at document start, then driven to the place-order button by
drive.Drive. The browser signs; the sidecar only fires.
"""
from __future__ import annotations

import json
import random
from pathlib import Path

from playwright.async_api import BrowserContext, Page, Playwright

from .config import Bot, Config
from .drive import Drive
from .fingerprint import gate, profile as fp, probe
from .log import JsonlLog
from .session import warmup
from .settings import DriveCfg
from .sign.harvest import Harvested, harvest
from .ui import inject
from .ui.store import Store


class FingerprintMismatch(RuntimeError):
    pass


class BotRuntime:
    def __init__(self, cfg: Config, bot: Bot, log: JsonlLog, store: Store,
                 dcfg: DriveCfg) -> None:
        self.cfg = cfg
        self.bot = bot
        self.log = log
        self.store = store
        self.dcfg = dcfg
        self.bp = cfg.bypass
        self.prof = fp.load_or_mint(bot.profile_path, seed=bot.id,
                                    explicit_binary=self.bp.executable,
                                    refresh_geometry=True)
        self.ctx: BrowserContext | None = None
        self.page: Page | None = None

    @property
    def base(self) -> str:
        return f"https://shopee.{self.cfg.sale.region}"

    def _stealth(self) -> str:
        """Config literal, then the script. Both in ONE init script so the
        reader can never run before the writer."""
        body = Path(fp.__file__).with_name("patches.js").read_text(encoding="utf-8")
        cfg = json.dumps(self.prof.stealth_cfg(not self.bp.native_ua))
        return f"window.__FP__={cfg};\n{body}"

    async def start(self, pw: Playwright, position: tuple[int, int]) -> None:
        launch: dict = {"headless": False,
                        "args": fp.launch_args(self.prof, position)}
        if self.bp.executable:
            launch["executable_path"] = self.bp.executable
        elif self.bp.channel:
            launch["channel"] = self.bp.channel
        kwargs = fp.context_args(self.prof, self.bot.proxy, self.bp.native_ua)
        self.ctx = await pw.chromium.launch_persistent_context(
            user_data_dir=str(Path(self.bot.profile_path).with_suffix("")),
            **launch, **kwargs)
        self.page = self.ctx.pages[0] if self.ctx.pages else await self.ctx.new_page()
        await self.page.add_init_script(script=self._stealth())
        await inject.install(self.page, self.bot.id)
        await self.page.bring_to_front()
        self.log.write(bot_id=self.bot.id, event="browser_start",
                       channel=self.bp.channel or self.bp.executable,
                       ua=self.prof.ua)

        if self.bp.fp_strict:
            await self.verify_fingerprint()

    async def verify_fingerprint(self) -> None:
        """Refuse to warm up on a contradictory browser."""
        assert self.page
        await self.page.goto("about:blank")
        await self.page.set_content("<html><body></body></html>")
        actual = await probe.dump(self.page)
        fails = gate.consistency(self.prof, actual)
        for f in fails:
            self.log.write(bot_id=self.bot.id, event="fp_fail", detail=f)
        if fails:
            raise FingerprintMismatch(f"{self.bot.id}: {len(fails)} contradiction(s): {fails[:3]}")

    def drive(self) -> Drive:
        assert self.page
        return Drive(page=self.page, cfg=self.dcfg, log=self.log,
                     store=self.store, bot_id=self.bot.id)

    async def land(self) -> None:
        """Mint SPC_F on the homepage before anything else.

        Landing straight on a product or a checkout with no SPC_F is the single
        most common way to get the hard wall: the edge has no session context to
        attach the request to.
        """
        assert self.page
        await self.page.goto(self.base, wait_until="domcontentloaded")
        verdict = await warmup.probe(self.page)
        self.log.write(bot_id=self.bot.id, event="land", verdict=verdict.value)
        if verdict.value in ("HARD_BLOCK", "BANNED"):
            raise warmup.Blocked(verdict)

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