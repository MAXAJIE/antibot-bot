from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any


class JsonlLog:
    """Append-only JSONL. One row per call, never buffered."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, **fields: Any) -> None:
        fields.setdefault("ts", time.time_ns())
        with self.path.open("a") as fh:
            fh.write(json.dumps(fields, separators=(",", ":")) + "\n")