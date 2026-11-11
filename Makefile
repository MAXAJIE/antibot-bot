.PHONY: setup build test clean
setup:
	python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"
build:
	cd sidecar && go build -o ../bin/sidecar .
test:
	python -m pytest -q
clean:
	rm -rf bin logs .venv