import sys

from shopee_sniper.config import load
from shopee_sniper.log import JsonlLog
from shopee_sniper.net.pool import Pool


def main() -> int:
    cfg = load(sys.argv[1] if len(sys.argv) > 1 else "config/bots.yaml")
    pool = Pool(cfg.proxy.max_p50_ms, cfg.proxy.preflight_attempts,
                JsonlLog("logs/proxy.jsonl"))
    pool.preflight_all([b.proxy for b in cfg.bots])
    for pf in pool.eligible():
        print(f"OK  {pf.proxy.host}:{pf.proxy.port}  {pf.p50_ms:.0f}ms  {pf.exit_ip}")
    dead = [pf for pf in pool._results.values() if not pf.eligible]
    for pf in dead:
        print(f"BAD {pf.proxy.host}:{pf.proxy.port}  {pf.p50_ms:.0f}ms")
    print(f"\n{len(pool.eligible())} eligible, {len(dead)} rejected")
    return 0 if pool.eligible() else 1


if __name__ == "__main__":
    raise SystemExit(main())