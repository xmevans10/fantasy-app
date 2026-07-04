"""Career-grain aggregation tests (M17) — weighted-average math correctness and grouping."""
from tools.ingest.career import build_career_rows
from tools.ingest.models import RawSeason


def _pitcher(year, ip, era, whip, bb, er, so=0, w=0, losses=0, saves=0):
    return RawSeason(
        name="Test Pitcher", team_abbr="NYY", season_year=year, sport="baseball", position="P",
        stats={"innings_pitched": ip, "wins": w, "losses": losses, "saves": saves,
               "strike_outs": so, "base_on_balls": bb, "earned_runs": er, "era": era, "whip": whip},
        source="mlb_stats",
    )


def test_era_whip_weighted_average_is_exact():
    # IP-weighted average of ERA/WHIP reduces to the true aggregate ratio (see career.py
    # docstring): era_i * ip_i = earned_runs_i * 9, so the weighted mean recovers the
    # real total-earned-runs/total-IP ratio exactly, not just an approximation.
    seasons = [
        _pitcher(2020, 100.0, 2.70, 1.10, bb=30, er=30),
        _pitcher(2021, 200.0, 2.25, 1.00, bb=50, er=50),
    ]
    rows = build_career_rows(seasons)
    assert len(rows) == 1
    r = rows[0]
    assert r.career is True
    assert r.stats["innings_pitched"] == 300.0
    assert r.stats["earned_runs"] == 80
    assert r.stats["era"] == 2.4                      # 80*9/300
    assert abs(r.stats["whip"] - (1.10 * 100 + 1.00 * 200) / 300) < 1e-3   # rounded to 3dp


def _hitter(year, ab, hits, doubles, triples, hr, bb, avg, obp, slg, ops, pa=None):
    return RawSeason(
        name="Test Hitter", team_abbr="NYY", season_year=year, sport="baseball", position="H",
        stats={"plate_appearances": pa or ab, "at_bats": ab, "hits": hits, "doubles": doubles,
               "triples": triples, "home_runs": hr, "runs": 0, "rbi": 0, "base_on_balls": bb,
               "stolen_bases": 0, "avg": avg, "obp": obp, "slg": slg, "ops": ops},
        source="mlb_stats",
    )


def test_hitter_rate_stats_weighted_by_at_bats_and_ops_derived():
    seasons = [
        _hitter(2020, 500, 150, 30, 2, 20, 80, 0.300, 0.400, 0.500, 0.900),
        _hitter(2021, 520, 140, 25, 1, 25, 60, 140 / 520, 0.350, 0.480, 0.830),
    ]
    rows = build_career_rows(seasons)
    assert len(rows) == 1
    r = rows[0]
    assert r.stats["at_bats"] == 1020
    assert r.stats["hits"] == 290
    assert abs(r.stats["avg"] - 290 / 1020) < 1e-3
    expected_obp = (0.400 * 580 + 0.350 * 580) / 1160   # weighted by (at_bats+walks)
    assert abs(r.stats["obp"] - expected_obp) < 1e-3
    assert abs(r.stats["ops"] - (r.stats["obp"] + r.stats["slg"])) < 1e-9


def test_pitcher_rows_never_get_a_phantom_ops():
    seasons = [_pitcher(2020, 100.0, 2.70, 1.10, bb=30, er=30),
               _pitcher(2021, 200.0, 2.25, 1.00, bb=50, er=50)]
    rows = build_career_rows(seasons)
    assert "ops" not in rows[0].stats
    assert "obp" not in rows[0].stats


def _nba_season(year, games, ppg, rpg):
    return RawSeason(
        name="Test Baller", team_abbr="LAL", season_year=year, sport="nba", position="F",
        stats={"games": games, "ppg": ppg, "rpg": rpg, "apg": 0, "spg": 0, "bpg": 0,
               "fg_pct": 0.5, "ts_pct": 0.55},
        source="espn",
    )


def test_nba_per_game_rates_weighted_by_games_matches_real_totals():
    # Career PPG should equal total points / total games, which the games-weighted
    # average produces exactly since ppg_i * games_i = that season's real point total.
    seasons = [_nba_season(2020, 70, 30.0, 8.0), _nba_season(2021, 82, 25.0, 10.0)]
    rows = build_career_rows(seasons)
    r = rows[0]
    total_points = 70 * 30.0 + 82 * 25.0
    total_games = 152
    assert abs(r.stats["ppg"] - total_points / total_games) < 1e-3
    assert r.stats["games"] == 152


def test_single_season_player_produces_no_career_row():
    seasons = [_pitcher(2020, 100.0, 2.70, 1.10, bb=30, er=30)]
    assert build_career_rows(seasons) == []


def test_excludes_single_game_and_already_career_rows():
    game_row = RawSeason(name="Ghost", team_abbr="KC", season_year=2020, sport="nfl",
                         position="RB", stats={"rushing_yards": 150}, week=12, opponent="DEN")
    career_row = RawSeason(name="Ghost", team_abbr="KC", season_year=2021, sport="nfl",
                           position="RB", stats={"rushing_yards": 9000}, career=True)
    assert build_career_rows([game_row, career_row]) == []


def test_groups_separately_by_position_for_two_way_players():
    # A two-way player (hitting AND pitching rows) must get separate career rows per
    # position, not one row conflating both stat blocks.
    seasons = [
        _hitter(2020, 500, 150, 30, 2, 20, 80, 0.300, 0.400, 0.500, 0.900),
        _hitter(2021, 520, 140, 25, 1, 25, 60, 140 / 520, 0.350, 0.480, 0.830),
        _pitcher(2020, 100.0, 2.70, 1.10, bb=30, er=30),
        _pitcher(2021, 200.0, 2.25, 1.00, bb=50, er=50),
    ]
    for s in seasons:
        object.__setattr__(s, "name", "Shohei Twoway")
    rows = build_career_rows(seasons)
    positions = {r.position for r in rows}
    assert positions == {"H", "P"}
    assert len(rows) == 2


def test_career_player_id_is_stable_and_distinct_from_season_ids():
    seasons = [_pitcher(2020, 100.0, 2.70, 1.10, bb=30, er=30),
               _pitcher(2021, 200.0, 2.25, 1.00, bb=50, er=50)]
    row = build_career_rows(seasons)[0]
    assert row.player_id == "test-pitcher-career"
    assert row.player_id not in {s.player_id for s in seasons}
