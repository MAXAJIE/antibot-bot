"""Gate 7. Solver accuracy on synthetic pairs, no network and no browser.

Synthetic pairs only prove the algorithm is not inverted. Real tiles carry
shadow and JPEG noise and score lower.
"""
from __future__ import annotations

import argparse
import random

import cv2
import numpy as np

from shopee_sniper.captcha.slider import LowScore, curve, gap

TOL = 6


def pair(x: int, rng: np.random.Generator) -> tuple[bytes, bytes]:
    bg = np.clip(245 + rng.integers(-3, 4, (160, 360, 3)), 0, 255).astype(np.uint8)
    tile = np.full((70, 70, 3), 245, np.uint8)
    cv2.rectangle(tile, (6, 6), (64, 64), (40, 40, 40), 3)
    cv2.circle(tile, (35, 35), 13, (95, 95, 95), -1)
    bg[45:115, x:x + 70] = tile
    ok1, b1 = cv2.imencode(".png", bg)
    ok2, b2 = cv2.imencode(".png", tile)
    assert ok1 and ok2
    return b1.tobytes(), b2.tobytes()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20)
    a = ap.parse_args()
    rng = np.random.default_rng(7)
    hits = 0
    for i in range(a.n):
        true_x = int(rng.integers(90, 280))
        bg, tile = pair(true_x, rng)
        try:
            found, score = gap(bg, tile)
        except LowScore as exc:
            print(f"{i:02d} low score {exc}")
            continue
        ok = abs(found - true_x) <= TOL
        hits += ok
        print(f"{i:02d} true={true_x} found={found} score={score:.3f} "
              f"{'HIT' if ok else 'MISS'}")
    rate = hits / a.n
    print(f"\n{rate:.0%} within {TOL}px")
    c = curve(180, random.Random(1))
    print(f"curve: {len(c)} points, overshoot {max(p[0] for p in c) - 180:.0f}px")
    return 0 if rate >= 0.8 else 1


if __name__ == "__main__":
    raise SystemExit(main())