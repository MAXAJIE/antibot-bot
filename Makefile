.PHONY: setup build test clean
setup:
	python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"
build:
	cd sidecar && go build -o ../bin/sidecar .
test:
	python -m pytest -q
clean:
	rm -rf bin logs .venv

.PHONY: gates smoke drive drive-test console
gates:
	python -m tools.slider --n 20
	python -m tools.election --bots 6 --dry
	python -m tools.rehearsal --bots 6

smoke:
	python -m tools.smoke --bots 6

drive:
	python -m tools.drive --mode test --keep-open

drive-test:
	python -m shopee_sniper.orchestrator.run --mode test --yes

console:
	python -m tools.console --log logs/sale.jsonl