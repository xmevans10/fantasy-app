"""The weekly in-season refresh's two moving parts: the nflverse 2025+ release cutover
(legacy `player_stats` is frozen at 2024) and the current-season cache eviction."""
from tools.ingest.providers import http, nfl_nflverse


def test_legacy_years_use_the_player_stats_release(monkeypatch):
    urls = []

    def fake_fetch(url, **kwargs):
        urls.append(url)
        return "player_id,player_display_name\n"

    monkeypatch.setattr(nfl_nflverse, "fetch_text", fake_fetch)
    nfl_nflverse.fetch_year(2024)
    assert "player_stats/player_stats_season_2024.csv" in urls[0]


def test_2025_and_later_use_the_stats_player_release(monkeypatch):
    urls = []

    def fake_fetch(url, **kwargs):
        urls.append(url)
        return "player_id,player_display_name\n"

    monkeypatch.setattr(nfl_nflverse, "fetch_text", fake_fetch)
    nfl_nflverse.fetch_year(2025)
    nfl_nflverse.fetch_year(2026)
    assert "stats_player/stats_player_reg_2025.csv" in urls[0]
    assert "stats_player/stats_player_reg_2026.csv" in urls[1]


def test_num_any_reads_whichever_interceptions_column_exists():
    assert nfl_nflverse._num_any({"interceptions": "12"}, "interceptions", "passing_interceptions") == 12.0
    assert nfl_nflverse._num_any({"passing_interceptions": "14"}, "interceptions", "passing_interceptions") == 14.0
    assert nfl_nflverse._num_any({}, "interceptions", "passing_interceptions") == 0.0
    # A present-but-empty legacy column wins (0.0), never falling through to the other key.
    assert nfl_nflverse._num_any({"interceptions": "", "passing_interceptions": "9"},
                                 "interceptions", "passing_interceptions") == 0.0


def test_evict_current_season_removes_only_live_entries(tmp_path, monkeypatch):
    monkeypatch.setattr(http, "CACHE_DIR", tmp_path)
    live = ["nflverse_season_2026.csv", "nfl_roster_2025.csv", "tennis_wta_matches_2026.csv",
            "espn_nba_stats_12345.json"]
    keep = ["nflverse_season_2010.csv", "nfl_history_1987.csv", "espn_nba_search_lebron-james.json",
            "bref_nba_seasons.csv"]
    for name in live + keep:
        (tmp_path / name).write_text("x")

    removed = http.evict_current_season(2026)

    assert removed == len(live)
    remaining = {p.name for p in tmp_path.iterdir()}
    assert remaining == set(keep)


# MARK: name-based headshot fallback (nfl_players.pick_headshot)

from tools.ingest.providers.nfl_players import pick_headshot


def test_pick_headshot_single_compatible_candidate_wins():
    cands = [{"headshot": "http://x/a.png", "rookie_season": "1989", "last_season": "1998"}]
    assert pick_headshot(cands, 1994) == "http://x/a.png"


def test_pick_headshot_missing_era_bounds_pass():
    cands = [{"headshot": "http://x/a.png", "rookie_season": "", "last_season": "1998"}]
    assert pick_headshot(cands, 1971) == "http://x/a.png"


def test_pick_headshot_era_mismatch_rejected():
    cands = [{"headshot": "http://x/a.png", "rookie_season": "2015", "last_season": "2024"}]
    assert pick_headshot(cands, 1985) == ""


def test_pick_headshot_ambiguous_names_yield_nothing():
    cands = [
        {"headshot": "http://x/sr.png", "rookie_season": "1980", "last_season": "1995"},
        {"headshot": "http://x/jr.png", "rookie_season": "1985", "last_season": "1999"},
    ]
    # 1990 falls in both eras — two compatible candidates, so refuse to guess.
    assert pick_headshot(cands, 1990) == ""
    # 1982 predates junior's era — exactly one compatible candidate remains.
    assert pick_headshot(cands, 1982) == "http://x/sr.png"
