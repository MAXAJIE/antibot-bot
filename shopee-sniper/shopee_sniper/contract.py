"""Phase 0 artifact loader.

Header ORDER is stored data and is replayed verbatim - order is fingerprint.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

REQUIRED = ("endpoint", "method", "header_order", "headers", "body", "captured_at")


@dataclass(frozen=True)
class Fixture:
    endpoint: str
    method: str
    header_order: tuple[str, ...]
    headers: dict[str, str]
    body: str
    captured_at: int
    ttl_curve: tuple[tuple[float, bool], ...]

    def ordered_headers(self) -> list[tuple[str, str]]:
        missing = set(self.header_order) - set(self.headers)
        if missing:
            raise ValueError(f"header_order references absent headers: {missing}")
        return [(h, self.headers[h]) for h in self.header_order]

    def ttl_safe_s(self, safety: float) -> float:
        accepts = [off for off, ok in self.ttl_curve if ok]
        if not accepts:
            raise ValueError("ttl_curve has no accepted offsets - re-measure")
        return max(accepts) * safety


def load(path: str | Path) -> Fixture:
    raw = json.loads(Path(path).read_text())
    for k in REQUIRED:
        if k not in raw:
            raise ValueError(f"fixture missing {k!r}")
    return Fixture(
        endpoint=raw["endpoint"],
        method=raw["method"],
        header_order=tuple(raw["header_order"]),
        headers=dict(raw["headers"]),
        body=raw["body"],
        captured_at=int(raw["captured_at"]),
        ttl_curve=tuple((float(o), bool(ok)) for o, ok in raw.get("ttl_curve", [])),
    )


def lint(path: str | Path) -> list[str]:
    problems: list[str] = []
    try:
        fx = load(path)
    except Exception as exc:
        return [f"unloadable: {exc}"]
    for h in ("af-ac-enc-dat", "x-csrftoken", "x-api-source", "referer"):
        if h not in fx.headers:
            problems.append(f"missing critical header {h!r}")
    if not fx.ttl_curve:
        problems.append("ttl_curve empty - TTL unmeasured, harvest lead is a guess")
    if fx.headers.get("content-type") != "application/json":
        problems.append("content-type not application/json")
    return problems