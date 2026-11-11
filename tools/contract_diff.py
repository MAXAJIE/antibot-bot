"""Gate 1 upkeep. Weekly cron: diff a fresh capture against the baseline.

Exit 1 on any order or set drift so the cron mails instead of silently passing.
"""
from __future__ import annotations

import argparse

from shopee_sniper import contract
from shopee_sniper.observe import headerhash


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--live", required=True)
    a = ap.parse_args()
    base = contract.load(a.baseline)
    live = contract.load(a.live)
    problems = headerhash.diff(list(base.header_order), list(live.header_order))
    if base.body != live.body:
        problems.append("body shape changed")
    if base.endpoint != live.endpoint:
        problems.append(f"endpoint {base.endpoint} -> {live.endpoint}")
    for p in problems:
        print(f"DRIFT {p}")
    if not problems:
        print("contract stable")
        print(f"hash {headerhash.header_hash(base.ordered_headers())}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())