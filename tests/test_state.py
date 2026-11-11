import pytest

from shopee_sniper.session.state import Preconditions, Session, State, TransitionError


def armed() -> Session:
    s = Session(bot_id="b1")
    s.warm()
    s.ready()
    s.pre = Preconditions(True, True, True, True, True, True, 20, 15)
    s.arm()
    return s


def test_happy_path() -> None:
    s = armed()
    s.fire()
    s.placed("123")
    assert s.state is State.PLACED


def test_arm_blocked_without_preconditions() -> None:
    s = Session(bot_id="b1")
    s.warm()
    s.ready()
    with pytest.raises(TransitionError):
        s.arm()


def test_arm_names_the_gap() -> None:
    s = Session(bot_id="b1")
    s.warm()
    s.ready()
    s.pre = Preconditions(cookies_present=True)
    with pytest.raises(TransitionError) as exc:
        s.arm()
    assert "spc_f_present" in str(exc.value)


def test_fire_blocked_when_disarmed() -> None:
    s = armed()
    s.pre.checkout_token_fresh = False
    with pytest.raises(TransitionError):
        s.fire()


def test_illegal_jump() -> None:
    s = Session(bot_id="b1")
    with pytest.raises(TransitionError):
        s.fire()


def test_challenge_budget() -> None:
    s = armed()
    assert s.challenge("x") is True
    s.ready()
    s.arm()
    assert s.challenge("y") is True
    s.ready()
    s.arm()
    assert s.challenge("z") is False