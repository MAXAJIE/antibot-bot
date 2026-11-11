# Phases 6-9

Implemented: race, squad, runner, browser runtime, console, overlay, slider,
OTP, detection, header-order forensics, metrics, and the missing gates.

## What is verified offline

    python -m pytest -q
    python -m tools.slider --n 20
    python -m tools.election --bots 6
    python -m tools.rehearsal --bots 6
    python -m shopee_sniper.observe.metrics logs/*.jsonl

## What is not

- `bot.py` cart body, payment/shipping selectors, and the `detect.py` marker
  table are shaped guesses. They need a Phase 0 capture to become facts.
- `tools/ja3.py` compares against a recording, not a baked constant. Record
  once per Chrome major: `python -m tools.ja3 --record contract/ja3_131.json`.
- `tools/slider.py` scores synthetic tiles. Real tiles are noisier.
- `run.py` places real orders. `--no-browser` only skips the browser.

## Gate order still applies

Gate 1 (contract) must be green before any live run. A stale fixture is a
guaranteed 403 or a burned token, not a slow order.

## Known conflict in the spec

The planbook sets the needle at T0-15ms and clamps everyone else to
[-40ms, +180ms]. That lets part of the pack fire before the needle. Kept as
specified; if the needle must lead, clamp to [-15, 180].

## Failure triage

`logs/*.jsonl` carries `event`, `status`, `ttl_remaining`, `overshoot_ms`,
`send_error_ms` and `headers_hash`. Status first: 403 is fingerprint or IP,
never timing. Then ttl. Then hash diff. Only then the account.

## Budgets

3 challenges per bot per sale, 2 retries per shot, one proxy per bot for the
whole session. Quorum abort above 50% challenged.