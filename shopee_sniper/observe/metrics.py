"""Phase 9 Prometheus counters, derived from the JSONL journal.

Derived rather than in-process: a crashed run still exposes its last numbers and
the scraper never sits on the fire path.
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

EVENTS = ("shot", "winner", "challenged", "banned", "retry", "quorum_abort",
          "race_skip", "give_up", "late_fire", "shot_error")


def collect(paths: list[Path]) -> Counter:
    c: Counter = Counter()
    for p in paths:
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            ev = row.get("event")
            if ev in EVENTS:
                c[f"event_{ev}"] += 1
            status = row.get("status")
            try:
                code = int(status)
            except (TypeError, ValueError):
                continue
            if code == 403:
                c["status_403"] += 1
            if 200 <= code < 300:
                c["status_2xx"] += 1
    return c


def render(c: Counter, prefix: str = "sniper") -> str:
    out = []
    for key in sorted(c):
        out.append(f"# TYPE {prefix}_{key} counter")
        out.append(f"{prefix}_{key} {c[key]}")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    paths = [Path(a) for a in args] or sorted(Path("logs").glob("*.jsonl"))
    if not paths:
        print("no journals", file=sys.stderr)
        return 1
    sys.stdout.write(render(collect(paths)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())