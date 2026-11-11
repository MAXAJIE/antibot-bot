"""Gate: does the browser agree with itself?

Launches one bot's browser against a local origin, reads ~30 surfaces, and fails
on any contradiction. --headers also prints the raw request header block so
duplicate client hints and ordering are visible.

Run this before every sale. A green fpcheck plus a green captcha probe is the
difference between 'blocked' and 'slow'.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import re
import threading

# gate.consistency collapses the Chrome build before comparing, so it tolerates
# both the reduced and the full form. Assert the reduced form explicitly: it is
# the only one a stock Chrome puts on the wire since M110.
_REDUCED_UA = re.compile(
    r"Mozilla/5\.0 \(Windows NT 10\.0; Win64; x64\) AppleWebKit/537\.36 "
    r"\(KHTML, like Gecko\) Chrome/\d+\.0\.0\.0 Safari/537\.36")
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from shopee_sniper import config, settings
from shopee_sniper.fingerprint import gate, probe
from shopee_sniper.fingerprint import profile as fp


class Echo(BaseHTTPRequestHandler):
    seen: list[list[tuple[str, str]]] = []

    def log_message(self, *a) -> None:
        pass

    def do_GET(self) -> None:
        if self.path == "/echo":
            Echo.seen.append(list(self.headers.items()))
        body = b"<html><body>ok</body></html>"
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve() -> tuple[ThreadingHTTPServer, int]:
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Echo)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_port


async def run(config_path: str, headers: bool) -> int:
    cfg = config.load(config_path)
    extra = settings.load(config_path)
    bp = extra.bypass
    bot = cfg.bots[0]
    prof = fp.load_or_mint(bot.profile_path, bot.id, bp.executable,
                           refresh_geometry=True)

    srv, port = serve()
    base = f"http://127.0.0.1:{port}"
    from playwright.async_api import async_playwright
    pw = await async_playwright().start()
    kwargs = fp.context_args(prof, None, bp.native_ua)
    launch: dict = {"headless": False, "args": fp.launch_args(prof, (60, 60))}
    if bp.executable:
        launch["executable_path"] = bp.executable
    elif bp.channel:
        launch["channel"] = bp.channel
    ctx = await pw.chromium.launch_persistent_context(
        user_data_dir=str(Path(bot.profile_path).with_suffix("")),
        **launch, **kwargs)
    try:
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        body = Path(fp.__file__).with_name("patches.js").read_text(encoding="utf-8")
        await page.add_init_script(
            script=f"window.__FP__={json.dumps(prof.stealth_cfg(bp.native_ua))};\n{body}")
        await page.goto(f"{base}/", wait_until="load")
        actual = await probe.dump(page)

        fails = gate.consistency(prof, actual)
        if not _REDUCED_UA.fullmatch(actual.get("ua") or ""):
            fails.append(f"navigator.userAgent is not UA-reduced: "
                         f"{actual.get('ua')!r} (want Chrome/<major>.0.0.0)")
        width = max(len(k) for k in actual)
        for k in sorted(actual):
            v = actual[k]
            if isinstance(v, str) and len(v) > 78:
                v = v[:75] + "..."
            print(f"  {k.ljust(width)}  {v}")

        if headers:
            await page.goto(f"{base}/echo", wait_until="load")
            await page.wait_for_timeout(400)
            print("\n  request headers as sent:")
            names = []
            for block in Echo.seen:
                for n, v in block:
                    print(f"    {n}: {v[:90]}")
                    names.append(n.lower())
            dupes = {n for n in names if names.count(n) > 1}
            if dupes:
                fails.append(f"duplicate request headers: {sorted(dupes)}")

            # The JS brand list and the Sec-CH-UA header are derived from the
            # same source in real Chrome: same order, same GREASE value. A gate
            # that only checks membership passes a spoofed list that disagrees
            # with the wire, which is exactly the contradiction that survived
            # the last run.
            ch = next((v for n, v in (Echo.seen[-1] if Echo.seen else [])
                       if n.lower() == "sec-ch-ua"), "")
            if ch:
                hdr = []
                for part in ch.split(","):
                    if not part.strip():
                        continue
                    name = part.split(";")[0].strip().strip('"')  # Chrome 157 uses hyphens on both surfaces
                    ver = part.split("v=")[1].strip().strip('"') if "v=" in part else ""
                    hdr.append((name, ver))
                js = [(str(b.get("brand")), str(b.get("version")))
                      for b in (actual.get("brands") or []) if isinstance(b, dict)]
                if hdr != js:
                    fails.append(f"sec-ch-ua header {hdr} vs userAgentData.brands {js} "
                                 "(order and GREASE must agree)")

        print()
        if fails:
            for f in fails:
                print(f"  FAIL {f}")
            print(f"\n  {len(fails)} contradiction(s)")
            return 1
        print("  OK  no contradictions")
        return 0
    finally:
        await ctx.close()
        await pw.stop()
        srv.shutdown()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/bots.yaml")
    ap.add_argument("--headers", action="store_true")
    a = ap.parse_args()
    return asyncio.run(run(a.config, a.headers))


if __name__ == "__main__":
    raise SystemExit(main())