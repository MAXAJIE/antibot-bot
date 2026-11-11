"""Phase 3. Session state machine with guarded transitions.

Guards matter more than the enum: ARMED is only legal when every precondition
holds, and a session that leaves ARMED must re-earn it. Disarming is the one
legal step back, and only from ARMED.
"""
from __future__ import annotations

import enum
import time
from dataclasses import dataclass, field


class State(enum.Enum):
    COLD = "COLD"
    WARMING = "WARMING"
    READY = "READY"
    ARMED = "ARMED"
    FIRING = "FIRING"
    PLACED = "PLACED"
    FAILED = "FAILED"
    CHALLENGED = "CHALLENGED"
    BANNED = "BANNED"


TRANSITIONS: dict[State, set[State]] = {
    State.COLD: {State.WARMING, State.BANNED},
    State.WARMING: {State.READY, State.CHALLENGED, State.BANNED, State.FAILED},
    State.READY: {State.ARMED, State.CHALLENGED, State.BANNED, State.FAILED},
    State.ARMED: {State.FIRING, State.READY, State.CHALLENGED, State.BANNED,
                  State.FAILED},
    State.FIRING: {State.PLACED, State.FAILED, State.CHALLENGED, State.BANNED},
    State.PLACED: {State.FAILED},
    State.FAILED: {State.READY, State.WARMING},
    State.CHALLENGED: {State.READY, State.BANNED},
    State.BANNED: set(),
}

TERMINAL = {State.PLACED, State.BANNED}


@dataclass
class Preconditions:
    cookies_present: bool = False
    spc_f_present: bool = False
    cart_staged: bool = False
    checkout_token_fresh: bool = False
    payment_selected: bool = False
    shipping_selected: bool = False
    rtt_samples: int = 0
    rtt_min_samples: int = 15

    def missing(self) -> list[str]:
        out = []
        for name in ("cookies_present", "spc_f_present", "cart_staged",
                     "checkout_token_fresh", "payment_selected",
                     "shipping_selected"):
            if not getattr(self, name):
                out.append(name)
        if self.rtt_samples < self.rtt_min_samples:
            out.append(f"rtt_samples({self.rtt_samples}/{self.rtt_min_samples})")
        return out

    def satisfied(self) -> bool:
        return not self.missing()


class TransitionError(RuntimeError):
    pass


@dataclass
class Session:
    bot_id: str
    state: State = State.COLD
    challenges_used: int = 0
    retries: int = 0
    pre: Preconditions = field(default_factory=Preconditions)
    history: list[tuple[float, State, str]] = field(default_factory=list)

    def _move(self, to: State, reason: str) -> None:
        if to not in TRANSITIONS[self.state]:
            raise TransitionError(f"{self.state.value} -> {to.value} illegal ({reason})")
        self.history.append((time.time(), to, reason))
        self.state = to

    def warm(self) -> None:
        self._move(State.WARMING, "warm-up start")

    def ready(self) -> None:
        self._move(State.READY, "warm-up complete")

    def arm(self) -> None:
        missing = self.pre.missing()
        if missing:
            raise TransitionError(f"cannot ARM, missing {missing}")
        self._move(State.ARMED, "preconditions met")

    def disarm(self, reason: str) -> None:
        if self.state is State.ARMED:
            self._move(State.READY, reason)

    def fire(self) -> None:
        if not self.pre.satisfied():
            raise TransitionError(f"cannot FIRE, missing {self.pre.missing()}")
        self._move(State.FIRING, "T0")

    def placed(self, order_id: str) -> None:
        self._move(State.PLACED, f"order {order_id}")

    def fail(self, reason: str) -> None:
        if self.state is State.FAILED:
            return
        if State.FAILED in TRANSITIONS[self.state]:
            self._move(State.FAILED, reason)

    def challenge(self, reason: str) -> bool:
        """Returns True if budget remains."""
        self.challenges_used += 1
        if State.CHALLENGED in TRANSITIONS[self.state]:
            self._move(State.CHALLENGED, reason)
        return self.challenges_used < 3

    def ban(self, reason: str) -> None:
        if State.BANNED in TRANSITIONS[self.state]:
            self._move(State.BANNED, reason)
        else:
            self.state = State.BANNED

    def can_retry(self, cap: int) -> bool:
        return self.retries < cap and self.state not in TERMINAL