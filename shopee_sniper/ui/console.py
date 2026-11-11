"""Phase 7 operator console. Stdlib only, one page, poll every 500ms.

Deliberately not a framework: this must come up on a machine where nothing but
the venv exists, and it must not compete with the fire path for a loop.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .store import Store

PAGE = """<!doctype html><meta charset=utf-8><title>sniper</title>
<style>
body{font:13px/1.4 ui-monospace,monospace;background:#111;color:#ddd;margin:0;padding:16px}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #222}
th{color:#666;font-weight:400}
#h{background:#3a0d0d;padding:8px;margin-bottom:12px;display:none}
#h.on{display:block}
button{background:#222;color:#ddd;border:1px solid #444;padding:4px 10px;cursor:pointer}
.CHALLENGED{color:#e8b} .BANNED{color:#e55} .PLACED{color:#5d5} .ARMED{color:#5ad}
</style>
<div id=h>HALTED</div>
<div><button onclick="post('halt')">HALT</button>
<button onclick="post('resume')">RESUME</button>
<button onclick="post('arm')">ARM</button></div>
<table><thead><tr><th>bot<th>state<th>rtt<th>ttl<th>offset<th>status<th>event<th>handoff</thead>
<tbody id=b></tbody></table>
<script>
const post=(a)=>fetch('/api/'+a,{method:'POST'});
async function tick(){
 const s=await (await fetch('/api/state')).json();
 document.getElementById('h').className=s.halted?'on':'';
 document.getElementById('b').innerHTML=Object.entries(s.bots).map(([k,v])=>
  `<tr><td>${k}<td class=${v.state}>${v.state}<td>${v.rtt_ms.toFixed(0)}`
  +`<td>${v.ttl_s.toFixed(1)}<td>${v.offset_ms.toFixed(0)}<td>${v.last_status||'-'}`
  +`<td>${v.last_event}<td>${v.handoff}`).join('');
}
tick(); setInterval(tick,500);
</script>"""


def make_handler(store: Store):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a) -> None:
            pass

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/":
                self._send(200, PAGE.encode(), "text/html; charset=utf-8")
            elif self.path == "/api/state":
                self._send(200, json.dumps(store.snapshot()).encode(),
                           "application/json")
            else:
                self._send(404, b"no", "text/plain")

        def do_POST(self) -> None:
            route = {
                "/api/halt": store.halt,
                "/api/resume": store.resume,
            }.get(self.path)
            if route:
                route()
                self._send(200, b"{}", "application/json")
            else:
                self._send(404, b"no", "text/plain")

    return H


def serve(store: Store, host: str = "127.0.0.1", port: int = 8732,
          background: bool = True) -> ThreadingHTTPServer:
    srv = ThreadingHTTPServer((host, port), make_handler(store))
    if background:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv