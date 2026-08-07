"""Pagination regression guards: PostgREST caps a single response at its own configured max
(Supabase defaults to 1000 rows) regardless of a requested `limit`, and NFL alone has ~14k
`player_seasons` rows. A naive single-request fetch silently truncates to that cap -- this
bit `tools.ingest.grid`'s live verification (a viable-looking NFL grid came back "no viable
grid from 1000 seasons" on a re-run, purely from which arbitrary 1000-row slice PostgREST
happened to return), so every catalog read has to page.

Both catalog readers page by **keyset** (`id=gt.<last>` + `order=id`), never Range/OFFSET.
That started as `fetch_existing_catalog_ids`'s fix for the 2026-07-14 statement-timeout kill
and now covers `fetch_player_seasons` too: measured against the live table, its page 1 came
back in 0.6s while the page at offset 8000 took 4.3s, and one career fetch under load hit the
statement timeout (57014) outright. The tests below pin the keyset shape for both."""
import io
import json
import urllib.error
from unittest.mock import patch
from urllib.parse import unquote as urllib_parse_unquote

import pytest

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


def _season_row(index: int) -> dict:
    return {"id": f"nfl-player{index:02d}-2020", "name": f"Player{index}", "team_abbr": "SF",
            "season_year": 2000 + index, "sport": "nfl", "position": "WR", "stats": {},
            "career": False}


def _keyset_server(rows: list[dict], server_cap: int, seen: list[str]):
    """A PostgREST stand-in that caps every response at `server_cap` rows and honours
    `id=gt.<last>`, so the fetch under test has to page correctly to see everything."""
    def fake_urlopen(req, timeout=60):
        seen.append(req.full_url)
        assert "Range" not in req.headers, "offset paging is exactly the regression"
        params = dict(part.split("=", 1) for part in req.full_url.split("?", 1)[1].split("&"))
        last = urllib_parse_unquote(params["id"][3:]) if "id" in params else None  # strip "gt."
        remaining = [r for r in sorted(rows, key=lambda r: r["id"])
                     if last is None or r["id"] > last]
        return _Resp(json.dumps(remaining[:server_cap]).encode("utf-8"))
    return fake_urlopen


def test_fetch_player_seasons_pages_past_the_first_response_cap(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "key")

    all_rows = [_season_row(i) for i in range(5)]
    seen: list[str] = []
    monkeypatch.setattr(upsert.urllib.request, "urlopen",
                        _keyset_server(all_rows, server_cap=2, seen=seen))

    rows = upsert.fetch_player_seasons("nfl", page_size=2)
    assert [r["name"] for r in rows] == [f"Player{i}" for i in range(5)]
    assert len(seen) == 3       # 2 + 2 + 1 (the short page stops the loop)
    assert all("order=id" in url for url in seen)
    # `id` is selected even though no caller reads it — it IS the paging cursor.
    assert all("select=id," in url for url in seen)


def test_fetch_player_seasons_columns_are_opt_in(monkeypatch):
    """The Grid's column set stays the default; whoami_pool asks for the wider one. Widening
    the default instead would put three unused columns on The Grid's 79k-row soccer pull."""
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "key")

    seen: list[str] = []
    monkeypatch.setattr(upsert.urllib.request, "urlopen",
                        _keyset_server([], server_cap=2, seen=seen))

    upsert.fetch_player_seasons("nfl")
    assert "headshot" not in seen[0] and "first_year" not in seen[0]

    seen.clear()
    upsert.fetch_player_seasons("nfl", columns=upsert.WHOAMI_CATALOG_COLUMNS)
    assert "headshot" in seen[0] and "first_year" in seen[0] and "last_year" in seen[0]


def test_fetch_existing_catalog_ids_pages_by_keyset_not_offset(monkeypatch):
    """Regression guard for the 2026-07-14 statement-timeout kill: existing-id fetches must
    page by keyset (`id=gt.<last>` + `order=id`), never by Range/offset — deep OFFSET pages
    over the doubled (~460k-row) table exceeded the server's statement timeout (57014) and
    died mid-pipeline. Simulates a server cap of 2 rows per response, like the real one."""
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "key")

    all_ids = [f"nfl-player-{i}-2020" for i in range(5)]
    requested_urls: list[str] = []

    def fake_urlopen(req, timeout=60):
        requested_urls.append(req.full_url)
        assert "Range" not in req.headers, "offset paging is exactly the regression"
        query = dict(part.split("=", 1) for part in req.full_url.split("?", 1)[1].split("&"))
        last = urllib_parse_unquote(query["id"][3:]) if "id" in query else None  # strip "gt."
        remaining = [i for i in sorted(all_ids) if last is None or i > last]
        server_cap = 2
        return _Resp(json.dumps([{"id": i} for i in remaining[:server_cap]]).encode("utf-8"))

    monkeypatch.setattr(upsert.urllib.request, "urlopen", fake_urlopen)

    ids = upsert.fetch_existing_catalog_ids("nfl", page_size=2)
    assert ids == set(all_ids)
    # 0..1, 2..3, 4, then the empty page that stops the loop
    assert len(requested_urls) == 4
    assert all("order=id.asc" in u for u in requested_urls)


def test_fetch_player_seasons_stops_on_an_empty_final_page(monkeypatch):
    """A run of full pages followed by an empty one must terminate. Keyset paging can't infer
    "done" from a short page when the row count is an exact multiple of the page size, so the
    empty response is the real stop condition — an unhandled one loops forever."""
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "key")

    all_rows = [_season_row(i) for i in range(4)]     # exactly 2 full pages, then empty
    seen: list[str] = []
    monkeypatch.setattr(upsert.urllib.request, "urlopen",
                        _keyset_server(all_rows, server_cap=2, seen=seen))

    rows = upsert.fetch_player_seasons("nfl", page_size=2)
    assert len(rows) == 4
    assert len(seen) == 3        # 2 + 2 + the empty page that ends it


def test_get_json_retries_a_transient_timeout():
    # The failure that killed a ~2h catalog run (2026-07-26): a bare socket TimeoutError
    # mid-pagination, on a read path that had no retry while the write path did.
    calls = {"n": 0}

    class _Resp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return b'[{"id": "x"}]'

    def _flaky(req, timeout=None):
        calls["n"] += 1
        if calls["n"] < 3:
            raise TimeoutError("The read operation timed out")
        return _Resp()

    with patch("urllib.request.urlopen", side_effect=_flaky), \
         patch("time.sleep"):
        out = upsert._get_json("https://example/x", {}, what="probe")
    assert out == [{"id": "x"}]
    assert calls["n"] == 3


def test_get_json_gives_up_after_four_attempts():
    with patch("urllib.request.urlopen", side_effect=TimeoutError("nope")), \
         patch("time.sleep"), \
         pytest.raises(RuntimeError, match="probe failed after 4 attempts"):
        upsert._get_json("https://example/x", {}, what="probe")


def test_get_json_does_not_retry_a_real_http_error():
    # A 4xx is a payload/permission problem — retrying can't fix it and would just stall.
    err = urllib.error.HTTPError("https://example/x", 403, "Forbidden", {}, io.BytesIO(b"denied"))
    with patch("urllib.request.urlopen", side_effect=err), \
         pytest.raises(RuntimeError, match="probe failed \\(403\\)"):
        upsert._get_json("https://example/x", {}, what="probe")
