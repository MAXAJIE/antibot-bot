"""Gate 5. Replay a fixture through the sidecar and report accept/reject."""
from __future__ import annotations

import argparse
import json
import time
import urllib.request

from shopee_sniper import contract


def rpc(url: str, path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        url.rstrip("/") + path, data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--host", default="shopee.sg")
    ap.add_argument("--sidecar", default="http://127.0.0.1:8731")
    a = ap.parse_args()

    fx = contract.load(a.fixture)
    rpc(a.sidecar, "/warm", {"ConnID": "replay", "Host": a.host,
                             "SNI": a.host, "PingSec": 0})
    t0 = time.time()
    res = rpc(a.sidecar, "/shot", {
        "ConnID": "replay", "Host": a.host, "Method": fx.method,
        "Path": fx.endpoint, "Headers": [list(h) for h in fx.ordered_headers()],
        "Body": fx.body})
    if res.get("error"):
        print("ERROR", res["error"])
        return 1
    print(f"status={res['status']} age={time.time() - t0:.2f}s")
    print(res.get("body", "")[:600])
    print("ACCEPT" if 200 <= res["status"] < 300 else "REJECT")
    return 0 if 200 <= res["status"] < 300 else 1


if __name__ == "__main__":
    raise SystemExit(main())