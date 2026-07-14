"""Transfermarkt full-squad sweep tests — pure aggregation over the dataset's
appearances/games shape (including the derived-clean-sheet join and season-end-year
detection), plus a loader round-trip over the committed CSV format."""
from tools.ingest.providers import transfermarkt_soccer
from tools.ingest.providers.transfermarkt_soccer import (
    _aggregate, _index_games, _real_image, _short_code, load_seasons)


def _game(game_id, comp="GB1", season=2022, date="2022-10-01",
          home="31", home_goals=2, away="631", away_goals=0):
    return {"game_id": game_id, "competition_id": comp, "season": str(season),
            "date": date, "home_club_id": home, "home_club_goals": str(home_goals),
            "away_club_id": away, "away_club_goals": str(away_goals)}


def _appearance(player, game_id, club, comp="GB1", goals=0, assists=0):
    return {"player_id": player, "game_id": game_id, "player_club_id": club,
            "competition_id": comp, "goals": str(goals), "assists": str(assists)}


def test_index_games_marks_european_seasons_with_end_year():
    games, end_years = _index_games([
        # A cross-year (Aug–May) season: half the games fall in the next calendar year.
        _game("g1", season=2022, date="2022-08-06"),
        _game("g2", season=2022, date="2023-05-28"),
        # A calendar-year season stays on its own label.
        _game("g3", comp="MLS1", season=2022, date="2022-03-01"),
        _game("g4", comp="MLS1", season=2022, date="2022-11-05"),
    ])
    assert end_years[("GB1", 2022)] == 2023
    assert end_years[("MLS1", 2022)] == 2022
    assert games["g1"] == ("GB1", 2022, "31", 2, "631", 0)


def test_aggregate_counts_appearances_goals_assists_and_derived_clean_sheets():
    games, _ = _index_games([
        _game("g1", home="31", home_goals=2, away="631", away_goals=0),   # LIV keep CS
        _game("g2", home="631", home_goals=1, away="31", away_goals=1),   # nobody does
        _game("g3", home="31", home_goals=0, away="631", away_goals=3),   # CHE keep CS
    ])
    rows = [
        _appearance("alisson", "g1", "31"),
        _appearance("alisson", "g2", "31"),
        _appearance("alisson", "g3", "31"),
        _appearance("salah", "g1", "31", goals=2, assists=0),
        _appearance("salah", "g2", "31", goals=1, assists=1),
    ]
    agg = _aggregate(rows, games, keep_comps={"GB1"})
    keeper = agg[("alisson", "31", "GB1", 2022)]
    assert keeper["appearances"] == 3
    assert keeper["clean_sheets"] == 1        # only g1 — conceded in g2 and g3
    scorer = agg[("salah", "31", "GB1", 2022)]
    assert scorer["appearances"] == 2 and scorer["goals"] == 3 and scorer["assists"] == 1


def test_aggregate_skips_other_competitions_pre_2012_and_unknown_games():
    games, _ = _index_games([
        _game("g1"),
        _game("g_old", season=2005, date="2005-10-01"),
    ])
    rows = [
        _appearance("p", "g1", "31"),
        _appearance("p", "g1", "31", comp="CL"),      # not a kept competition
        _appearance("p", "g_old", "31"),              # pre-2012 fragment
        _appearance("p", "g_missing", "31"),          # appearance with no game row
    ]
    agg = _aggregate(rows, games, keep_comps={"GB1"})
    assert agg[("p", "31", "GB1", 2022)]["appearances"] == 1
    assert len(agg) == 1


def test_short_code_reproduces_seed_codes_and_survives_boilerplate():
    assert _short_code("Manchester City Football Club") == "MCI"
    assert _short_code("Manchester United Football Club") == "MUN"
    assert _short_code("Liverpool Football Club") == "LIV"
    assert _short_code("Real Madrid Club de Fútbol") == "RMA"
    assert _short_code("Burnley Football Club") == "BUR"
    # Corporate/defunct junk never leaks into a code.
    assert _short_code("FC Khimki (-2025)") == "KHI"
    assert _short_code("Girona Fútbol Club S. A. D.") == "GIR"
    assert _short_code("B SAD").isalnum()


def test_real_image_rejects_the_default_placeholder():
    real = "https://img.a.transfermarkt.technology/portrait/header/418560-17.png?lm=1"
    assert _real_image(real) == real
    assert _real_image("https://img.a.transfermarkt.technology/portrait/header/default.jpg?lm=1") == ""
    assert _real_image("") == ""


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "soccer_transfermarkt_seasons.csv"
    csv_path.write_text(
        "name,team_abbr,season_year,position,appearances,goals,assists,clean_sheets,headshot\n"
        "Alisson,LIV,2019,GK,38,0,0,21,https://img.a.transfermarkt.technology/alisson.jpg\n",
        encoding="utf-8")
    monkeypatch.setattr(transfermarkt_soccer, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "soccer-alisson-2019"
    assert s.sport == "soccer" and s.position == "GK" and s.team_abbr == "LIV"
    assert s.stats == {"appearances": 38.0, "goals": 0.0, "assists": 0.0,
                       "clean_sheets": 21.0}
    assert s.source == "transfermarkt"
    assert s.headshot.endswith("alisson.jpg")


def test_load_seasons_empty_when_refresh_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(transfermarkt_soccer, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []
