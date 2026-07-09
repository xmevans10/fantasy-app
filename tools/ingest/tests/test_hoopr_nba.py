"""hoopR NBA sweep tests — pure pivot logic against the long (player, stat) row shape
the parquet files carry, plus a loader round-trip over the committed CSV format."""
import pytest

from tools.ingest.providers import hoopr_nba
from tools.ingest.providers.hoopr_nba import _pivot_season, load_seasons


def _long_rows(athlete_id, name, season, position, team_slug, *,
               gp="55", pts="27.4", reb="8.5", ast="8.3", stl="1.3", blk="0.6",
               fg="10.1-19.9", ft="5.1-7.6", fg_pct="51.0", fg3_pct="33.9"):
    """One player-season's 'averages' rows in the file's long format."""
    stats = {
        "gamesPlayed": gp, "avgPoints": pts, "avgRebounds": reb, "avgAssists": ast,
        "avgSteals": stl, "avgBlocks": blk, "fieldGoalPct": fg_pct,
        "threePointFieldGoalPct": fg3_pct,
        "avgFieldGoalsMade-avgFieldGoalsAttempted": fg,
        "avgFreeThrowsMade-avgFreeThrowsAttempted": ft,
    }
    return [{
        "season": season, "athlete_id": athlete_id, "athlete_display_name": name,
        "athlete_position_abbreviation": position, "team_slug": team_slug,
        "category": "averages", "stat_name": k, "display_value": v,
    } for k, v in stats.items()]


def test_pivots_one_row_per_player_season():
    rows = _pivot_season(_long_rows(1966, "LeBron James", 2019, "SF", "los-angeles-lakers"))
    assert len(rows) == 1
    r = rows[0]
    assert r["name"] == "LeBron James" and r["season_year"] == 2019
    assert r["team_abbr"] == "LAL"
    assert r["position"] == "F"          # SF collapses into the catalog's F bucket
    assert r["games"] == 55 and r["ppg"] == 27.4
    assert r["fg_pct"] == 0.51           # percent → fraction
    # TS% = pts / (2 * (FGA + 0.44*FTA)), same formula as espn_nba.parse_seasons
    assert r["ts_pct"] == round(27.4 / (2 * (19.9 + 0.44 * 7.6)), 3)


def test_traded_player_keeps_highest_games_real_team_stint():
    rows = _pivot_season(
        _long_rows(7, "Traded Guy", 2019, "PG", "2018-19 Totals", gp="60")
        + _long_rows(7, "Traded Guy", 2019, "PG", "phoenix-suns", gp="45")
        + _long_rows(7, "Traded Guy", 2019, "PG", "chicago-bulls", gp="15"))
    assert len(rows) == 1
    assert rows[0]["team_abbr"] == "PHX" and rows[0]["games"] == 45


def test_totals_only_player_kept_with_empty_team():
    # ~16% of a season file: traded players with no per-stint rows at all. They stay
    # real catalog/theme-pool rows; Draft & Spin's spins skip empty abbrs on their own.
    rows = _pivot_season(_long_rows(8, "Journeyman", 2019, "SG", "2018-19 Totals"))
    assert len(rows) == 1
    assert rows[0]["team_abbr"] == "" and rows[0]["position"] == "G"


def test_unknown_position_dropped_and_gf_mapped():
    assert _pivot_season(_long_rows(9, "No Position", 2005, "NA", "utah-jazz")) == []
    rows = _pivot_season(_long_rows(10, "Tweener", 2005, "GF", "utah-jazz"))
    assert rows and rows[0]["position"] == "F"


def test_unknown_team_slug_fails_loudly():
    with pytest.raises(ValueError, match="las-vegas-somethings"):
        _pivot_season(_long_rows(11, "Future Player", 2031, "C", "las-vegas-somethings"))


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "nba_hoopr_seasons.csv"
    csv_path.write_text(
        "name,athlete_id,team_abbr,season_year,position,games,ppg,rpg,apg,spg,bpg,"
        "fg_pct,fg3_pct,ts_pct\n"
        "LeBron James,1966,LAL,2019,F,55,27.4,8.5,8.3,1.3,0.6,0.51,0.339,0.588\n",
        encoding="utf-8")
    monkeypatch.setattr(hoopr_nba, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "lebron-james-2019"
    assert s.sport == "nba" and s.source == "hoopr"
    assert s.team_abbr == "LAL" and s.position == "F"
    assert s.stats["ppg"] == 27.4 and s.stats["games"] == 55.0
    assert s.headshot.endswith("/1966.png")


def test_load_seasons_empty_when_sweep_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(hoopr_nba, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []
