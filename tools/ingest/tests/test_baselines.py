"""Era-adjustment baselines — population math and shape."""
from tools.ingest.baselines import MIN_SAMPLES, compute_baselines
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
