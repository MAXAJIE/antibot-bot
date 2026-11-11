"""Phase 9 header-order fingerprint.

Values rotate every shot (af-ac-enc-dat is time-derived), so the hash covers
NAMES in order only. Drift looks like a hash that moves while the body does not.
"""
from __future__ import annotations

import hashlib
from typing import Iterable

SEP = "\x1f"


def header_hash(pairs: Iterable[tuple[str, str]]) -> str:
    h = hashlib.sha256()
    for name, _ in pairs:
        h.update(name.lower().encode())
        h.update(SEP.encode())
    return h.hexdigest()[:16]


def names(pairs: Iterable[tuple[str, str]]) -> list[str]:
    return [n.lower() for n, _ in pairs]


def diff(expected: Iterable[str], actual: Iterable[str]) -> list[str]:
    """Human-readable drift. Empty list means the order still matches."""
    exp, act = list(expected), list(actual)
    if exp == act:
        return []
    out = [f"order changed at index {i}: {e!r} -> {a!r}"
           for i, (e, a) in enumerate(zip(exp, act)) if e != a]
    out += [f"missing {n!r}" for n in exp if n not in act]
    out += [f"unexpected {n!r}" for n in act if n not in exp]
    if not out:
        out.append(f"length {len(exp)} -> {len(act)}")
    return out