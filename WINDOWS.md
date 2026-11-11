# Windows 10 setup

make is not present by default. Use these instead of the Makefile targets.

    py -3.12 -m venv .venv
    .\.venv\Scripts\Activate.ps1
    pip install -e ".[dev]"
    cd sidecar; go build -o ..\bin\sidecar.exe .; cd ..
    python -m playwright install chromium

If Activate.ps1 is blocked:

    Set-ExecutionPolicy -Scope Process Bypass

The sidecar builds to bin\sidecar.exe. Set sidecar.url to http://127.0.0.1:8731
and run bin\sidecar.exe in its own window.

Go 1.22+ is required and is not part of a default Windows install:
https://go.dev/dl/ (windows-amd64 MSI). Open a fresh shell after installing.