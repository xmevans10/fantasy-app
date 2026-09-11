"""Era-adjustment baselines — population math and shape."""
from tools.ingest.baselines import (
    FANTASY_TOTAL, MIN_SAMPLES, QUALIFY, TOTAL_SCALE, _qualify_gate, _role, _total_scale,
    compute_baselines,
)
from tools.ingest.models import RawSeason


def _season(name, year, stats, sport="nfl", pos="WR"):
    return RawSeason(name=name, team_abbr="XXX", season_year=year,
                     sport=sport, position=pos, stats=stats)


def test_mean_and_std_over_recorders_only():
    # Five WR recorders + one zero (a non-receiver) for receiving_yards in 2020.
    seasons = [
        _season("A", 2020, {"receiving_yards": 1000}),
        _season("B", 2020, {"receiving_yards": 1000}),
        _season("C", 2020, {"receiving_yards": 1000}),
        _season("D", 2020, {"receiving_yards": 1000}),
        _season("E", 2020, {"receiving_yards": 2000}),
        _season("Lineman", 2020, {"receiving_yards": 0}),   # excluded: value not > 0
    ]
    rows = compute_baselines(seasons)
    ry = [r for r in rows if r["stat"] == "receiving_yards" and r["year"] == 2020]
    assert len(ry) == 1
    row = ry[0]
    assert row["count"] == 5                      # the zero is excluded
    assert row["mean"] == 1200.0                  # (1000*4 + 2000) / 5
    assert row["std"] > 0
    assert row["sport"] == "nfl"
    assert row["position"] == "WR"


def test_positions_are_separated():
    # Same stat/year, two positions → two distinct baselines.
    seasons = (
        [_season(f"W{i}", 2020, {"rushing_yards": 50 + i}, pos="WR") for i in range(MIN_SAMPLES)]
        + [_season(f"R{i}", 2020, {"rushing_yards": 1200 + i}, pos="RB") for i in range(MIN_SAMPLES)]
    )
    rows = [r for r in compute_baselines(seasons) if r["stat"] == "rushing_yards"]
    by_pos = {r["position"]: r for r in rows}
    assert set(by_pos) == {"WR", "RB"}
    assert by_pos["RB"]["mean"] > by_pos["WR"]["mean"]


def test_below_min_samples_dropped():
    seasons = [_season(f"P{i}", 2019, {"rushing_yards": 500 + i}) for i in range(MIN_SAMPLES - 1)]
    rows = compute_baselines(seasons)
    assert all(not (r["stat"] == "rushing_yards" and r["year"] == 2019) for r in rows)


def test_years_and_sports_are_separated():
    seasons = (
        [_season(f"N{i}", 2020, {"ppg": 20.0 + i}, sport="nba", pos="G") for i in range(MIN_SAMPLES)]
        + [_season(f"N{i}", 2021, {"ppg": 10.0 + i}, sport="nba", pos="G") for i in range(MIN_SAMPLES)]
    )
    rows = compute_baselines(seasons)
    by_year = {r["year"]: r for r in rows if r["stat"] == "ppg"}
    assert set(by_year) == {2020, 2021}
    assert by_year[2020]["mean"] > by_year[2021]["mean"]


# ── Position-aware QUALIFY/TOTAL_SCALE lookup (M31 generalisation) ────────────────────

def test_role_is_a_no_op_for_sports_without_a_split():
    # NFL/NBA have no _POSITION_ROLE entry — `_role` must hand the raw position straight
    # back, unchanged, for every position that sport can ever carry.
    assert _role("nfl", "WR") == "WR"
    assert _role("nfl", "QB") == "QB"
    assert _role("nba", "G") == "G"


def test_role_splits_hockey_goalie_from_every_skater_code():
    assert _role("hockey", "G") == "goalie"
    for code in ("C", "L", "R", "D"):
        assert _role("hockey", code) == "skater"


def test_qualify_gate_and_total_scale_unchanged_for_flat_sports():
    # A plain (stat, floor)/scale-key value must come back exactly as stored — no
    # dict-dispatch — for sports whose QUALIFY/TOTAL_SCALE entry isn't role-split.
    assert _qualify_gate("nfl", "WR") == QUALIFY["nfl"] == ("games", 10.0)
    assert _qualify_gate("nba", "G") == QUALIFY["nba"] == ("games", 40.0)
    assert _total_scale("nfl", "RB") == TOTAL_SCALE["nfl"] == "nfl_fantasy"
    assert _total_scale("nba", "F") == TOTAL_SCALE["nba"] == "nba_fantasy"


def test_qualify_gate_and_total_scale_split_by_hockey_role():
    assert _qualify_gate("hockey", "C") == ("games", 40.0)
    assert _qualify_gate("hockey", "D") == ("games", 40.0)
    assert _qualify_gate("hockey", "G") == ("games_started", 25.0)
    assert _total_scale("hockey", "L") == "hockey_skater_fantasy"
    assert _total_scale("hockey", "G") == "hockey_goalie_fantasy"


def test_unknown_sport_gate_and_scale_are_none():
    assert _qualify_gate("baseball", "1B") is None
    assert _total_scale("soccer", "FW") is None


# ── Hockey `fantasy_total` emission (M31) ─────────────────────────────────────────────

def _hockey_skater(name, year, games, points, goals=0, assists=0, pos="C"):
    stats = {"games": games, "points": points, "goals": goals, "assists": assists}
    return _season(name, year, stats, sport="hockey", pos=pos)


def _hockey_goalie(name, year, games, games_started, wins=0, shutouts=0):
    stats = {"games": games, "games_started": games_started, "wins": wins,
             "shutouts": shutouts}
    return _season(name, year, stats, sport="hockey", pos="G")


def test_hockey_skaters_qualify_on_games_not_games_started():
    # A skater with a full 82-game slate qualifies (>=40); one who barely dressed does not.
    seasons = [_hockey_skater(f"S{i}", 2020, games=60, points=50 + i, goals=25, assists=25)
               for i in range(MIN_SAMPLES)]
    seasons.append(_hockey_skater("Cameo", 2020, games=5, points=90, goals=50, assists=40))
    rows = compute_baselines(seasons)
    ft = [r for r in rows if r["stat"] == FANTASY_TOTAL and r["position"] == "C"
          and r["year"] == 2020]
    assert len(ft) == 1
    assert ft[0]["count"] == MIN_SAMPLES   # the cameo season never enters the pool


def test_hockey_goalies_qualify_on_games_started_with_their_own_lower_floor():
    # 30 games started clears the goalie gate (>=25) even though it would fail the
    # skater gate (>=40) — goalies structurally play a smaller share of the season.
    seasons = [_hockey_goalie(f"G{i}", 2019, games=35, games_started=30, wins=15 + i,
                              shutouts=2)
               for i in range(MIN_SAMPLES)]
    rows = compute_baselines(seasons)
    ft = [r for r in rows if r["stat"] == FANTASY_TOTAL and r["position"] == "G"
          and r["year"] == 2019]
    assert len(ft) == 1
    assert ft[0]["count"] == MIN_SAMPLES


def test_hockey_goalie_below_starts_floor_is_excluded_even_with_many_games():
    # 35 games played but only 15 starts (a backup) — must not qualify even though
    # `games` alone would clear a skater-style bar.
    seasons = [_hockey_goalie(f"G{i}", 2019, games=35, games_started=30) for i in range(MIN_SAMPLES)]
    seasons.append(_hockey_goalie("Backup", 2019, games=35, games_started=15))
    rows = compute_baselines(seasons)
    ft = [r for r in rows if r["stat"] == FANTASY_TOTAL and r["position"] == "G"
          and r["year"] == 2019]
    assert ft[0]["count"] == MIN_SAMPLES   # the backup's row never joins the population


def test_hockey_skater_and_goalie_fantasy_total_are_graded_on_different_scales():
    # A skater's fantasy_total must come from hockey_skater_fantasy (goals*3 + assists*2 +
    # ...), a goalie's from hockey_goalie_fantasy (wins*5 + shutouts*5 + ...) — grading a
    # goalie season on the skater scale (or vice versa) would silently score 0 for every
    # stat neither scale recognizes on the other role.
    skaters = [_hockey_skater(f"S{i}", 2021, games=60, points=0, goals=10 + i, assists=10)
               for i in range(MIN_SAMPLES)]
    rows = compute_baselines(skaters)
    ft = next(r for r in rows if r["stat"] == FANTASY_TOTAL and r["position"] == "C")
    # goals=10..14 (avg 12) * 3.0 + assists=10 * 2.0 = 36 + 20 = 56 average.
    assert ft["mean"] == 56.0

    goalies = [_hockey_goalie(f"G{i}", 2021, games=40, games_started=30, wins=20 + i,
                              shutouts=5)
               for i in range(MIN_SAMPLES)]
    rows = compute_baselines(goalies)
    ft = next(r for r in rows if r["stat"] == FANTASY_TOTAL and r["position"] == "G")
    # wins=20..24 (avg 22) * 5.0 + shutouts=5 * 5.0 = 110 + 25 = 135 average.
    assert ft["mean"] == 135.0
