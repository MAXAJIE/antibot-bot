import random

import cv2
import numpy as np
import pytest

from shopee_sniper.captcha.slider import LowScore, curve, delays, gap


def _tile(shape: bool = True) -> bytes:
    img = np.full((70, 70, 3), 245, np.uint8)
    if shape:
        cv2.rectangle(img, (6, 6), (64, 64), (40, 40, 40), 3)
        cv2.circle(img, (35, 35), 13, (95, 95, 95), -1)
    return cv2.imencode(".png", img)[1].tobytes()


def _pair(x: int) -> tuple[bytes, bytes]:
    rng = np.random.default_rng(0)
    bg = np.clip(245 + rng.integers(-3, 4, (160, 360, 3)), 0, 255).astype(np.uint8)
    bg[45:115, x:x + 70] = cv2.imdecode(
        np.frombuffer(_tile(), np.uint8), cv2.IMREAD_COLOR)
    return cv2.imencode(".png", bg)[1].tobytes(), _tile()


def test_gap_finds_tile() -> None:
    bg, tile = _pair(180)
    found, score = gap(bg, tile)
    assert abs(found - 180) <= 10
    assert score > 0.35


def test_flat_tile_rejected() -> None:
    bg, _ = _pair(180)
    with pytest.raises(LowScore):
        gap(bg, _tile(shape=False))


def test_threshold_rejects_weak_match() -> None:
    bg, tile = _pair(180)
    with pytest.raises(LowScore):
        gap(bg, tile, score_min=1.01)


def test_curve_shape() -> None:
    pts = curve(200, random.Random(5))
    xs = [p[0] for p in pts]
    assert 30 <= len(pts) <= 48
    assert xs[-1] == 200
    assert max(xs) > 200
    assert all(b >= a - 6 for a, b in zip(xs, xs[1:]))


def test_delays_bounds() -> None:
    d = delays(30, 800, random.Random(1))
    assert all(8 <= v <= 25 for v in d)