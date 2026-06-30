"""ESPN NBA parser tests — pure (no network), against a captured payload shape."""
from tools.ingest.providers.espn_nba import _attempted, parse_seasons

_NAMES = [
    "gamesPlayed", "gamesStarted", "avgMinutes",
    "avgFieldGoalsMade-avgFieldGoalsAttempted", "fieldGoalPct",
    "avgThreePointFieldGoalsMade-avgThreePointFieldGoalsAttempted", "threePointFieldGoalPct",
    "avgFreeThrowsMade-avgFreeThrowsAttempted", "freeThrowPct",
    "avgOffensiveRebounds", "avgDefensiveRebounds", "avgRebounds", "avgAssists",
    "avgBlocks", "avgSteals", "avgFouls", "avgTurnovers", "avgPoints",
]


def _row(year, team_slug, gp, pts, reb, ast, fga="18.9", fta="5.8"):
    return {
        "teamId": "5", "teamSlug": team_slug, "position": "F",
        "season": {"year": year, "displayName": f"{year-1}-{str(year)[2:]}"},
        "stats": [str(gp), str(gp), "39.5", f"7.9-{fga}", "41.7", "0.8-2.7", "29.0",
                  f"4.4-{fta}", "75.4", "1.3", "4.2", str(reb), str(ast),
                  "0.7", "1.6", "1.9", "3.5", str(pts)],
    }


def _payload(rows, teams=None):
    return {
        "teams": teams or {"cleveland-cavaliers": {"abbreviation": "CLE"}},
        "categories": [{"name": "averages", "names": _NAMES, "statistics": rows}],
    }


def test_parses_season_averages():
    seasons = parse_seasons("LeBron James",
                            _payload([_row(2004, "cleveland-cavaliers", 79, 20.9, 5.5, 5.9)]))
    assert 2004 in seasons
    s = seasons[2004]
    assert s.season_year == 2004
    assert s.team_abbr == "CLE"
    assert s.sport == "nba" and s.source == "espn"
    assert s.stats["ppg"] == 20.9
    assert s.stats["rpg"] == 5.5
    assert s.stats["apg"] == 5.9
    assert s.stats["games"] == 79
    # TS% = pts / (2 * (FGA + 0.44*FTA))
    assert s.stats["ts_pct"] == round(20.9 / (2 * (18.9 + 0.44 * 5.8)), 3)


def test_multi_team_season_keeps_more_games():
    rows = [
        _row(2020, "team-a", 12, 18.0, 4.0, 3.0),   # traded away early
        _row(2020, "team-b", 55, 24.0, 6.0, 5.0),   # bulk of the season
    ]
    teams = {"team-a": {"abbreviation": "AAA"}, "team-b": {"abbreviation": "BBB"}}
    s = parse_seasons("Some Player", _payload(rows, teams))[2020]
    assert s.stats["games"] == 55 and s.team_abbr == "BBB"  # the higher-games row wins


def test_attempted_parses_made_attempted_pair():
    assert _attempted("7.9-18.9") == 18.9
    assert _attempted("garbage") == 0.0
