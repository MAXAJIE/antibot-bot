"""Phase 7 console over a finished or running journal."""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from shopee_sniper.ui import console
from shopee_sniper.ui.store import Store

KEEP = ("event", "status", "rtt_ms", "overshoot_ms", "error")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="logs/sale.jsonl")
    ap.add_argument("--port", type=int, default=8732)
    a = ap.parse_args()
    store = Store()
    p = Path(a.log)
    if p.exists():
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            bot = row.get("bot_id")
            if bot:
                store.upsert(bot, **{k: v for k, v in row.items() if k in KEEP})
    srv = console.serve(store, port=a.port)
    print(f"http://127.0.0.1:{srv.server_port}")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        srv.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())