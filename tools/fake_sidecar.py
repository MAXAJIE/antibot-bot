"""Local stand-in for the Go sidecar. Same JSON contract, no TLS, no proxy.

Strict on purpose: a shot missing any required key comes back as an error, so
tools/smoke.py catches contract drift between fire.py and the sidecar before a
real sale does.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUIRED = ("connid", "host", "method", "path", "headers", "body")


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.warm: set[str] = set()
        self.shots: list[dict] = []
        self.winner_taken = False


def handler_for(st: State):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a) -> None:
            pass

        def _json(self, code: int, obj: dict) -> None:
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            self._json(200, {"status": 200}) if self.path == "/healthz" \
                else self._json(404, {"error": "no route"})

        def do_POST(self) -> None:
            n = int(self.headers.get("content-length") or 0)
            try:
                q = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return self._json(400, {"error": "bad json"})
            if self.path == "/warm":
                with st.lock:
                    st.warm.add(q.get("connid", ""))
                return self._json(200, {"status": 200})
            if self.path == "/close":
                with st.lock:
                    st.warm.discard(q.get("connid", ""))
                return self._json(200, {"status": 200})
            if self.path == "/shot":
                missing = [k for k in REQUIRED if k not in q]
                if missing:
                    return self._json(200, {"error": f"missing {missing}"})
                with st.lock:
                    if q["connid"] not in st.warm:
                        return self._json(200, {"error": "unknown connid"})
                    st.shots.append(q)
                    give = not st.winner_taken
                    if give:
                        st.winner_taken = True
                now = time.time_ns()
                body = '{"order_id":"SMOKE-1"}' if give else '{"ok":true}'
                return self._json(200, {"status": 200, "headers": [], "body": body,
                                        "tsendns": now, "tackns": now + 1_000_000})
            return self._json(404, {"error": "no route"})

    return H


def serve(port: int = 0) -> tuple[ThreadingHTTPServer, State]:
    st = State()
    srv = ThreadingHTTPServer(("127.0.0.1", port), handler_for(st))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, st


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8731)
    a = ap.parse_args()
    srv, _ = serve(a.port)
    print(f"fake sidecar on http://127.0.0.1:{srv.server_port}")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        srv.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())