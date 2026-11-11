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