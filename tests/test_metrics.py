import json
from pathlib import Path

from shopee_sniper.observe.metrics import collect, render


def _journal(tmp_path: Path) -> Path:
    p = tmp_path / "j.jsonl"
    rows = [
        {"event": "shot", "status": 200},
        {"event": "shot", "status": 403},
        {"event": "challenged", "status": 403},
        {"event": "winner", "status": 200},
        {"note": "no event"},
    ]
    p.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
    return p


def test_counts(tmp_path: Path) -> None:
    c = collect([_journal(tmp_path)])
    assert c["status_2xx"] == 2
    assert c["status_403"] == 2
    assert c["event_shot"] == 2
    assert c["event_winner"] == 1


def test_render_shape(tmp_path: Path) -> None:
    out = render(collect([_journal(tmp_path)]))
    assert "# TYPE sniper_status_2xx counter" in out