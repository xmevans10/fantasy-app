"""MLB single-game provider parser tests — pure (no network), against a captured
`stats=gameLog` payload shape (verified live against statsapi.mlb.com this session —
see providers/mlb_stats_games.py)."""
from tools.ingest.providers.mlb_stats_games import (
    _game_date_label,
    _hitting_game,
    _opponent_abbr,
    _pitching_game,
)


def _hitting_split(**stat_overrides):
    stat = {
        "plateAppearances": 5, "atBats": 5, "hits": 2, "doubles": 1, "triples": 0,
        "homeRuns": 0, "runs": 1, "rbi": 0, "baseOnBalls": 0, "stolenBases": 0,
    }
    stat.update(stat_overrides)
    return {
        "season": "2022", "team": {"id": 147}, "opponent": {"id": 111}, "date": "2022-04-08",
        "stat": stat,
    }


def _pitching_split(**stat_overrides):
    stat = {
        "inningsPitched": "6.0", "wins": 1, "losses": 0, "saves": 0, "strikeOuts": 11,
        "baseOnBalls": 2, "earnedRuns": 0,
    }
    stat.update(stat_overrides)
    return {
        "season": "2023", "team": {"id": 147}, "opponent": {"id": 111}, "date": "2023-06-01",
        "stat": stat,
    }


def test_parses_real_hitting_game():
    # Aaron Judge's real 2022-04-08 game log line (verified live against the actual API).
    row = _hitting_game("Aaron Judge", _hitting_split(), "https://headshot", 1)
    assert row is not None
    assert row.sport == "baseball" and row.position == "H" and row.team_abbr == "NYY"
    assert row.season_year == 2022
    assert row.stats["hits"] == 2
    assert row.week == 1
    assert row.opponent == "BOS"
    assert row.game_date == "Apr 8"


def test_parses_real_pitching_game():
    row = _pitching_game("Gerrit Cole", _pitching_split(), "https://headshot", 1)
    assert row is not None
    assert row.position == "P"
    assert row.stats["strike_outs"] == 11
    assert row.stats["innings_pitched"] == 6.0
    assert row.game_date == "Jun 1"


def test_skips_rows_with_unknown_team_id():
    split = _hitting_split()
    split["team"] = {"id": 999999}
    row = _hitting_game("Someone", split, "", 1)
    assert row is None


def test_skips_zero_plate_appearance_rows():
    row = _hitting_game("Bench Player", _hitting_split(plateAppearances=0), "", 1)
    assert row is None


def test_skips_zero_innings_pitched_rows():
    row = _pitching_game("Reliever", _pitching_split(inningsPitched="0.0"), "", 1)
    assert row is None


def test_opponent_abbr_unknown_id_returns_empty():
    assert _opponent_abbr({"opponent": {"id": 999999}}) == ""


def test_game_date_label_formats_iso_date():
    assert _game_date_label("2022-04-08") == "Apr 8"
    assert _game_date_label("2022-12-01") == "Dec 1"


def test_game_date_label_passes_through_unparseable():
    assert _game_date_label("") == ""
    assert _game_date_label("not-a-date") == "not-a-date"
