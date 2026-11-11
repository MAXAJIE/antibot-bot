import asyncio
import time

from shopee_sniper import contract
from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.orchestrator.election import Election
from shopee_sniper.orchestrator.race import Participant, Race, order_id
from shopee_sniper.session.state import Preconditions, Session
from shopee_sniper.timing.fire import ShotResult

CFG = load("config/bots.example.yaml")
FX = contract.Fixture(endpoint="/x", method="POST", header_order=("a",),
                      headers={"a": "b"}, body="{}", captured_at=0,
                      ttl_curve=((1.0, True),))


def armed(bot_id: str) -> Session:
    s = Session(bot_id=bot_id)
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def part(bot_id: str, age_ms: int = 0) -> Participant:
    return Participant(bot_id=bot_id, conn_id=bot_id, fixture=FX, rtt_ns=1_000_000,
                       harvested_at_ms=time.time_ns() // 1_000_000 - age_ms,
                       session=armed(bot_id))


def test_order_id_extraction() -> None:
    assert order_id('{"data":{"order_id":42}}') == "42"
    assert order_id('{"ok":true}') is None
    assert order_id("garbage") is None


def test_expired_ttl_skips() -> None:
    el = Election(t0_ns=0, needle_offset_ms=0, jitter_sigma_ms=1, clamp_ms=(0, 0))
    race = Race(CFG, JsonlLog("logs/t.jsonl"), el, 1.0, "http://x", "h", 0,
                fire_fn=lambda p, t: ShotResult(200, '{"order_id":1}', 1, 1, t, 0.0, 1))
    p = part("bot01", age_ms=5000)
    out = asyncio.run(race.run(time.time_ns(), [p]))
    assert out.winner is None
    assert p.session.state.value == "READY"