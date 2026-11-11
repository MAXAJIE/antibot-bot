# shopee-sniper

Phases 0-5: capture harness, fingerprint layer, signing harvester, session state
machine, timing engine, proxy pool, Go uTLS sidecar.

Phases 6-8 (multi-bot election, operator UI, captcha) are stubs with contracts
defined but no implementation.

## Why the Go sidecar exists

Python ssl cannot emit a Chrome ClientHello - the extension set and ordering
differ, so JA3 never matches. It also gives no SO_TIMESTAMPNS, no
TCP_FASTOPEN_CONNECT, and no absolute-time send. The sidecar owns the T0 shot
only. Everything else goes through the browser or curl_cffi.

## Order of work

Phase 0 first, always. Nothing downstream is trustworthy until contract
fixtures exist and reproduce.

    python -m capture.mitm_recorder --out contract/
    # drive a manual checkout through the proxied browser on :8080
    python -m tools.contract_lint contract/latest.json

## Gates

    python -m tools.ja3 --compare chrome
    python -m tools.replay --fixture contract/latest.json
    python -m tools.dryrun --shots 20

## Known gaps

- h2 SETTINGS are Chrome-pinned in sidecar/conn.go; re-pin on Chrome major bump.
- helloID() ignores the Chrome major and always returns HelloChrome_Auto.
- af-ac-enc-dat TTL is measured, not known.
- Slider captcha, election, and UI are unimplemented.