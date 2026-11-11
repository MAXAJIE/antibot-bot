import sys

from shopee_sniper import contract


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python -m tools.contract_lint <fixture.json>")
        return 2
    problems = contract.lint(sys.argv[1])
    if not problems:
        print("OK")
        return 0
    for p in problems:
        print("FAIL:", p)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())