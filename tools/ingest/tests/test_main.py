"""Tests for main.py's catalog assembly. Game-grain rows never reach the catalog
(on-device grading isn't built for single games — an explicit non-goal). Career-grain
rows DO reach it as of M17 (community career-puzzle creation)."""
from unittest.mock import patch

from tools.ingest.main import catalog_rows, merge_nfl_bio
from tools.ingest.models import RawSeason


def _season(name, **kw):
    base = dict(name=name, team_abbr="X", season_year=2015, sport="nfl",
                position="WR", stats={"receiving_yards": 1000.0})
    base.update(kw)
    return RawSeason(**base)


def test_catalog_excludes_game_grain_rows():
    rows = [
        _season("Season Guy"),
        _season("Game Guy", week=12, opponent="DEN"),
    ]
    out = catalog_rows(rows)
    names = {r["name"] for r in out}
    assert names == {"Season Guy"}


def test_catalog_includes_career_grain_rows():
    # M17: career creation needs a real career pool to search, so career rows now reach
    # the catalog alongside season rows — flagged via "career" so the client can scope a
    # career template's search to career-only (never mixing season + career in one pool).
    rows = [
        _season("Season Guy"),
        _season("Career Guy", career=True, meta={"first_year": "2015", "last_year": "2023"}),
    ]
    out = catalog_rows(rows)
    by_name = {r["name"]: r for r in out}
    assert set(by_name) == {"Season Guy", "Career Guy"}
    assert by_name["Season Guy"]["career"] is False
    assert by_name["Season Guy"]["first_year"] is None
    assert by_name["Career Guy"]["career"] is True
    assert by_name["Career Guy"]["first_year"] == 2015
    assert by_name["Career Guy"]["last_year"] == 2023


def test_catalog_carries_headshot_through():
    rows = [_season("Headshot Guy", headshot="https://example.com/p.jpg")]
    out = catalog_rows(rows)
    assert out[0]["headshot"] == "https://example.com/p.jpg"


def test_merge_nfl_bio_backfills_missing_headshot_from_registry():
    # Reproduces the real-world gap: a legend's season row has no headshot_url (common for
    # older/retired seasons), but the all-time players.csv registry has one.
    legend = _season("Priest Holmes", headshot="", meta={"gsis_id": "00-0007661"})
    with patch("tools.ingest.main.nfl_players.load_bio", return_value={
        "00-0007661": {"headshot": "https://static.www.nfl.com/legends/priest-holmes.png",
                       "college": "Texas"},
    }):
        merge_nfl_bio([legend])
    assert legend.headshot == "https://static.www.nfl.com/legends/priest-holmes.png"
    assert legend.meta["college"] == "Texas"
    assert "headshot" not in legend.meta   # popped — it's a fallback URL, not a filter dimension


def test_merge_nfl_bio_does_not_override_an_existing_headshot():
    current = _season("Active Guy", headshot="https://cdn.example/current.png",
                       meta={"gsis_id": "00-0000001"})
    with patch("tools.ingest.main.nfl_players.load_bio", return_value={
        "00-0000001": {"headshot": "https://static.www.nfl.com/stale.png"},
    }):
        merge_nfl_bio([current])
    assert current.headshot == "https://cdn.example/current.png"
