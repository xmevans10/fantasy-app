"""Tests for filter/grain handling in assemble + the generator viability gate.

Synthetic seasons only (no network)."""
from tools.ingest import assemble
from tools.ingest.models import RawSeason
from tools.ingest.themes import Filter, StatColumn, Theme

_COLS = [StatColumn("receiving_yards", "Rec Yds", "comma_int")]


def _wr(name, yards, *, week=None, college=None, headshot="h"):
    meta = {"college": college} if college else {}
    return RawSeason(name=name, team_abbr="X", season_year=2015, sport="nfl",
                     position="WR", stats={"receiving_yards": float(yards), "receptions": 80.0,
                                           "receiving_tds": 8.0},
                     headshot=headshot, week=week, opponent="DEN" if week else "", meta=meta)


def _theme(**kw):
    base = dict(key="t", title="T", sport="nfl", scale="nfl_skill_ppr",
                positions=frozenset({"WR"}), min_stats={}, columns=_COLS)
    base.update(kw)
    return Theme(**base)


def _pool(n_start=1000):
    # 10 WR seasons with descending yards → distinct, close grades + clean boundary.
    return [_wr(f"Player {i}", n_start + i * 60) for i in range(10)]


def test_filters_narrow_the_pool_below_viable():
    seasons = _pool()
    # Only 3 share the college → fewer than 8 candidates → no puzzle built.
    for s in seasons[:3]:
        s.meta["college"] = "LSU"
    theme = _theme(filters=(Filter("college", "eq", "LSU"),))
    assert assemble.build_keep4_rows(theme, seasons) == []


def test_no_filters_builds_a_puzzle():
    rows = assemble.build_keep4_rows(_theme(), _pool())
    assert rows and len(rows[0].content["players"]) == 8


def test_season_theme_excludes_game_rows():
    seasons = _pool()
    # Add 8 game-grain rows for distinct players; a season theme must ignore them.
    games = [_wr(f"Gamer {i}", 200, week=10) for i in range(8)]
    theme = _theme(grain="season")
    rows = assemble.build_keep4_rows(theme, seasons + games)
    names = {p["name"] for r in rows for p in r.content["players"]}
    assert not any(n.startswith("Gamer") for n in names)


def test_game_theme_excludes_season_rows_and_carries_context():
    games = [_wr(f"Gamer {i}", 150 + i * 20, week=12) for i in range(10)]
    theme = _theme(grain="game", scale="nfl_skill_ppr")
    rows = assemble.build_keep4_rows(theme, _pool() + games)
    assert rows
    players = rows[0].content["players"]
    assert all(p["name"].startswith("Gamer") for p in players)
    assert all(p["week"] == 12 and p["opponent"] == "DEN" for p in players)


def test_default_max_variants_is_one():
    # Regression: themes used to default to 3 near-duplicate variants per theme.
    # A large, evenly-spread pool would yield several windows if not capped to 1.
    seasons = [_wr(f"Player {i}", 1000 + i * 30) for i in range(40)]
    rows = assemble.build_keep4_rows(_theme(), seasons)
    assert len(rows) == 1
