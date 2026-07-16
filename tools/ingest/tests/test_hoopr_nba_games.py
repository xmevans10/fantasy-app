"""hoopR NBA single-game sweep tests — pure pivot logic against the wide `player_box` row
shape the parquet files carry (already one row per player-game, unlike the season file's
long pivot), plus a loader round-trip over the committed CSV format."""
from tools.ingest.providers import hoopr_nba_games
from tools.ingest.providers.hoopr_nba_games import (
    _game_date_label,
    _notable,
    _pivot_games,
    load_seasons,
)


def _box_row(athlete_id=1966, name="LeBron James", season=2019, position="SF",
             team_abbr="LAL", opp_abbr="BOS", game_date="2019-01-15",
             season_type=2, did_not_play=False, **stat_overrides):
    stat = {"points": 45, "rebounds": 8, "assists": 6, "steals": 2, "blocks": 1,
            "field_goals_made": 16}
    stat.update(stat_overrides)
    return {
        "season": season, "season_type": season_type, "athlete_id": athlete_id,
        "athlete_display_name": name, "athlete_position_abbreviation": position,
        "team_abbreviation": team_abbr, "opponent_team_abbreviation": opp_abbr,
        "game_date": game_date, "did_not_play": did_not_play,
        "athlete_headshot_href": f"https://example.com/{athlete_id}.png",
        **stat,
    }


def test_pivots_one_row_per_notable_game():
    rows = _pivot_games([_box_row()])
    assert len(rows) == 1
    r = rows[0]
    assert r["name"] == "LeBron James" and r["season_year"] == 2019
    assert r["team_abbr"] == "LAL" and r["opponent_abbr"] == "BOS"
    assert r["position"] == "F"          # SF collapses into the catalog's F bucket
    assert r["points"] == 45 and r["rebounds"] == 8
    assert r["game_date"] == "Jan 15"
    assert r["week"] == 1


def test_drops_non_notable_games():
    # A mundane box score (well under every "notable" bar) must never reach the CSV —
    # this is the filter that keeps the committed sweep from being every game ever played.
    assert _pivot_games([_box_row(points=8, rebounds=3, assists=2, steals=0, blocks=0)]) == []


def test_notable_thresholds():
    assert _notable({"points": 25})
    assert _notable({"rebounds": 15})
    assert _notable({"assists": 12})
    assert _notable({"steals": 5})
    assert _notable({"blocks": 5})
    assert _notable({"rebounds": 10, "assists": 10})
    assert not _notable({"points": 24, "rebounds": 9, "assists": 9})


def test_drops_playoff_and_preseason_games():
    assert _pivot_games([_box_row(season_type=3)]) == []
    assert _pivot_games([_box_row(season_type=1)]) == []


def test_drops_all_star_pseudo_teams():
    # The source data tags the All-Star Game's "EAST"/"WEST" rows season_type == 2
    # (regular season) alongside real games — must be excluded explicitly.
    assert _pivot_games([_box_row(team_abbr="EAST")]) == []
    assert _pivot_games([_box_row(team_abbr="WEST")]) == []


def test_drops_did_not_play_and_unknown_position():
    assert _pivot_games([_box_row(did_not_play=True)]) == []
    assert _pivot_games([_box_row(position="NA")]) == []


def test_sequential_week_index_within_player_season():
    rows = _pivot_games([
        _box_row(game_date="2019-01-20", points=30),
        _box_row(game_date="2019-01-15", points=41),
        _box_row(game_date="2019-01-25", points=28),
    ])
    assert [r["week"] for r in sorted(rows, key=lambda r: r["game_date"])] == [1, 2, 3]
    by_date = {r["game_date"]: r["week"] for r in rows}
    assert by_date["Jan 15"] == 1 and by_date["Jan 20"] == 2 and by_date["Jan 25"] == 3


def test_game_date_label_handles_strings_and_date_objects():
    import datetime as dt
    assert _game_date_label("2024-06-17") == "Jun 17"
    assert _game_date_label(dt.date(2024, 6, 17)) == "Jun 17"
    assert _game_date_label(dt.datetime(2024, 6, 17, 20, 30)) == "Jun 17"


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "nba_hoopr_games.csv"
    csv_path.write_text(
        "name,athlete_id,team_abbr,season_year,position,opponent_abbr,game_date,headshot,"
        "points,rebounds,assists,steals,blocks,field_goals_made,week\n"
        "LeBron James,1966,LAL,2019,F,BOS,Jan 15,https://example.com/1966.png,"
        "45,8,6,2,1,16,1\n",
        encoding="utf-8")
    monkeypatch.setattr(hoopr_nba_games, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "nba-lebron-james-2019-wk01"
    assert s.sport == "nba" and s.source == "hoopr_games"
    assert s.team_abbr == "LAL" and s.position == "F"
    assert s.week == 1 and s.opponent == "BOS" and s.game_date == "Jan 15"
    assert s.stats["points"] == 45.0 and s.stats["rebounds"] == 8.0
    assert s.headshot == "https://example.com/1966.png"


def test_load_seasons_empty_when_sweep_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(hoopr_nba_games, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []
