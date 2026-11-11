"""Phase 0 capture. Writes contract fixtures.

Run: python -m capture.mitm_recorder --out contract/
Then drive a manual checkout through the proxied browser on :8080.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from mitmproxy import ctx, http

WATCH = ("/api/v4/checkout/place_order", "/api/v4/checkout/get",
         "/api/v4/cart/update", "/api/v4/pdp/")
OUT = Path("contract")


class Recorder:
    def __init__(self) -> None:
        self.n = 0

    def response(self, flow: http.HTTPFlow) -> None:
        if not any(w in flow.request.path for w in WATCH):
            return
        order = [k.decode() for k, _ in flow.request.headers.fields]
        headers = {k.decode(): v.decode() for k, v in flow.request.headers.fields}
        rec = {
            "endpoint": flow.request.path.split("?")[0],
            "method": flow.request.method,
            "header_order": order,
            "headers": headers,
            "body": flow.request.get_text() or "",
            "captured_at": int(time.time() * 1000),
            "status": flow.response.status_code if flow.response else None,
            "ttl_curve": [],
        }
        OUT.mkdir(parents=True, exist_ok=True)
        self.n += 1
        (OUT / f"cap_{self.n:04d}.json").write_text(json.dumps(rec, indent=2))
        (OUT / "latest.json").write_text(json.dumps(rec, indent=2))
        ctx.log.info(f"captured {rec['method']} {rec['endpoint']} -> {rec['status']}")


addons = [Recorder()]


def main() -> None:
    global OUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="contract")
    ap.add_argument("--port", type=int, default=8080)
    a = ap.parse_args()
    OUT = Path(a.out)
    from mitmproxy.tools.main import mitmdump
    mitmdump(["-p", str(a.port), "-s", __file__])


if __name__ == "__main__":
    main()