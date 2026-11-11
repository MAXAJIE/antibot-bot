from shopee_sniper.ui.store import Store


def test_snapshot_is_a_copy() -> None:
    s = Store()
    s.upsert("b1", state="ARMED")
    snap = s.snapshot()
    snap["bots"]["b1"]["state"] = "BANNED"
    assert s.snapshot()["bots"]["b1"]["state"] == "ARMED"


def test_unknown_field_ignored() -> None:
    s = Store()
    s.upsert("b1", nope=1)
    assert "nope" not in s.snapshot()["bots"]["b1"]


def test_halt_flag() -> None:
    s = Store()
    assert not s.halted()
    s.halt()
    assert s.halted()
    s.resume()
    assert not s.halted()


def test_handoff_tracked() -> None:
    s = Store()
    s.handoff("b1", "slider failed")
    assert s.handoffs() == ["b1"]