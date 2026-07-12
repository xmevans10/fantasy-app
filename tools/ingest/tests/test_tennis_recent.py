"""Post-snapshot ATP (2019–2025) sweep tests — aggregation is shared with the ATP
provider; here we cover the recent-specific wiring: the year window starts exactly
where the frozen snapshot ends, and the loader round-trips the committed CSV with
source='tennis_recent'."""
from tools.ingest.providers import tennis_atp, tennis_recent
from tools.ingest.providers.tennis_recent import load_seasons


def test_year_window_starts_where_frozen_snapshot_ends():
    # tennis_atp.py's snapshot is frozen at 2018; this provider must cover 2019 onward
    # with no gap and no overlap (overlap would double-count seasons downstream).
    assert tennis_recent.MIN_YEAR == tennis_atp.MAX_YEAR + 1


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "tennis_recent_seasons.csv"
    csv_path.write_text(
        "name,country,season_year,matches_won,matches_lost,titles,grand_slams,headshot\n"
        "Jannik Sinner,ITA,2024,73,6,8,2,https://upload.wikimedia.org/sinner.jpg\n",
        encoding="utf-8")
    monkeypatch.setattr(tennis_recent, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "jannik-sinner-2024"
    assert s.sport == "tennis" and s.position == "Player"
    assert s.team_abbr == "ITA"                       # country stands in for team
    assert s.stats == {"matches_won": 73.0, "matches_lost": 6.0, "titles": 8.0, "grand_slams": 2.0}
    assert s.source == "tennis_recent"
    assert s.headshot.endswith("sinner.jpg")


def test_load_seasons_empty_when_sweep_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(tennis_recent, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []
