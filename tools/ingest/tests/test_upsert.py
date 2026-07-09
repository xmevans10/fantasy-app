"""Pagination regression guard: PostgREST caps a single response at its own configured max
(Supabase defaults to 1000 rows) regardless of a requested `limit`, and NFL alone has ~14k
`player_seasons` rows. A naive single-request fetch silently truncates to that cap -- this
bit `tools.ingest.grid`'s live verification (a viable-looking NFL grid came back "no viable
grid from 1000 seasons" on a re-run, purely from which arbitrary 1000-row slice PostgREST
happened to return). fetch_player_seasons must page through everything via Range headers."""
import json

from tools.ingest import upsert


class _Resp:
    def __init__(self, body: bytes):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_fetch_player_seasons_pages_past_the_first_response_cap(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "key")

    # Simulate a server that caps each response at 2 rows regardless of what's asked for —
    # same shape as PostgREST's real default row cap.
    total_rows = 5
    calls: list[str] = []

    def fake_urlopen(req, timeout=60):
        calls.append(req.headers.get("Range", ""))
        range_header = req.headers.get("Range", "0-1")
        start = int(range_header.split("-")[0])
        server_cap = 2
        page = [
            {"name": f"Player{i}", "team_abbr": "SF", "season_year": 2000 + i,
             "sport": "nfl", "position": "WR", "stats": {}, "career": False}
            for i in range(start, min(start + server_cap, total_rows))
        ]
        return _Resp(json.dumps(page).encode("utf-8"))

    monkeypatch.setattr(upsert.urllib.request, "urlopen", fake_urlopen)

    rows = upsert.fetch_player_seasons("nfl", page_size=2)
    assert len(rows) == total_rows
    assert [r["name"] for r in rows] == [f"Player{i}" for i in range(total_rows)]
    assert len(calls) == 3  # 0-1, 2-3, 4-5 (last one short — stops the loop)


def test_fetch_player_seasons_stops_on_empty_final_page(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "key")

    def fake_urlopen(req, timeout=60):
        range_header = req.headers.get("Range", "0-1")
        start = int(range_header.split("-")[0])
        if start >= 2:
            return _Resp(b"[]")
        return _Resp(json.dumps([{"name": "Only", "team_abbr": "SF", "season_year": 2000,
                                  "sport": "nfl", "position": "WR", "stats": {},
                                  "career": False}] * 2).encode("utf-8"))

    monkeypatch.setattr(upsert.urllib.request, "urlopen", fake_urlopen)

    rows = upsert.fetch_player_seasons("nfl", page_size=2)
    assert len(rows) == 2
