"""Phase 7 stub. Prints bot grid from the JSONL log."""
from __future__ import annotations

import json
from pathlib import Path


def render(log_path: str | Path) -> str:
    rows: dict[str, dict] = {}
    for line in Path(log_path).read_text().splitlines():
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "bot_id" in r:
            rows[r["bot_id"]] = r
    out = ["bot     last_event        status   rtt_ms  overshoot_ms"]
    for bot, r in sorted(rows.items()):
        out.append(f"{bot:<7} {r.get('event', '-'):<17} "
                   f"{str(r.get('status', '-')):<8} "
                   f"{str(r.get('rtt_ms', '-')):<7} {r.get('overshoot_ms', '-')}")
    return "\n".join(out)