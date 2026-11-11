"""Gate 3. Capture the sidecar's ClientHello and hash it.

A local sink stands in for the edge: the sidecar dials it with SNI pointed at
Shopee, we read the ClientHello, and the handshake is allowed to fail on the
certificate. Only the ClientHello matters here.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import socket
import threading
import urllib.request
from pathlib import Path


def _sink(hold: list[bytes], port_box: list[int], ready: threading.Event) -> None:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port_box.append(srv.getsockname()[1])
    ready.set()
    srv.settimeout(15)
    try:
        conn, _ = srv.accept()
        conn.settimeout(5)
        buf = b""
        while len(buf) < 5:
            buf += conn.recv(4096)
        need = 5 + int.from_bytes(buf[3:5], "big")
        while len(buf) < need:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
        hold.append(buf)
        conn.close()
    except OSError:
        pass
    finally:
        srv.close()


def _u16(b: bytes, i: int) -> tuple[int, int]:
    return int.from_bytes(b[i:i + 2], "big"), i + 2


def ja3(record: bytes) -> str:
    """JA3 over the raw ClientHello. GREASE is kept, as browsers keep it."""
    body = record[5:]
    i = 4 + 32
    sid = body[i]
    i += 1 + sid
    clen, i = _u16(body, i)
    ciphers = body[i:i + clen]
    i += clen
    comp = body[i]
    i += 1 + comp
    elen, i = _u16(body, i)
    exts = body[i:i + elen]
    curves, formats = b"", b""
    j = 0
    while j + 4 <= len(exts):
        et = int.from_bytes(exts[j:j + 2], "big")
        ln = int.from_bytes(exts[j + 2:j + 4], "big")
        data = exts[j + 4:j + 4 + ln]
        if et == 10 and len(data) > 2:
            n = int.from_bytes(data[0:2], "big")
            curves = data[2:2 + n]
        if et == 11 and len(data) > 1:
            n = data[0]
            formats = data[1:1 + n]
        j += 4 + ln
    parts = [
        str(int.from_bytes(body[0:2], "big")),
        "-".join(str(int.from_bytes(ciphers[k:k + 2], "big"))
                 for k in range(0, len(ciphers), 2)),
        "-".join(str(int.from_bytes(exts[k:k + 2], "big"))
                 for k in range(0, len(exts), 4) if k + 2 <= len(exts)),
        "-".join(str(int.from_bytes(curves[k:k + 2], "big"))
                 for k in range(0, len(curves), 2)),
        "-".join(str(b) for b in formats),
    ]
    return hashlib.md5(",".join(parts).encode()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sidecar", default="http://127.0.0.1:8731")
    ap.add_argument("--sni", default="shopee.sg")
    ap.add_argument("--record", default="")
    ap.add_argument("--expect", default="")
    a = ap.parse_args()

    hold: list[bytes] = []
    port_box: list[int] = []
    ready = threading.Event()
    th = threading.Thread(target=_sink, args=(hold, port_box, ready), daemon=True)
    th.start()
    ready.wait(5)
    host = f"127.0.0.1:{port_box[0]}"
    req = urllib.request.Request(
        a.sidecar.rstrip("/") + "/warm",
        data=json.dumps({"ConnID": "ja3", "Host": host, "SNI": a.sni}).encode(),
        headers={"content-type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception:
        pass
    th.join(10)
    if not hold:
        print("no ClientHello captured")
        return 1
    digest = ja3(hold[0])
    print(f"ja3 {digest}  bytes {len(hold[0])}")
    if a.record:
        Path(a.record).write_text(json.dumps({"sni": a.sni, "ja3": digest}, indent=2))
    if a.expect:
        want = json.loads(Path(a.expect).read_text())["ja3"]
        print("MATCH" if want == digest else f"DRIFT expected {want}")
        return 0 if want == digest else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())