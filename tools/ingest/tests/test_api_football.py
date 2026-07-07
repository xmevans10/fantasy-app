"""API-Football soccer provider tests — pure (`_get` monkeypatched), covering response
parsing, the free-tier soft-error skip, and the live-supersedes-seed dedup."""
from tools.ingest.models import RawSeason
from tools.ingest.providers import api_football


def _response(*players):
    return {"errors": [], "response": list(players)}, {}


def _player(name_initial, firstname, lastname, *, team="Manchester City",
            position="Attacker", appearances=30, goals=20, assists=5):
    return {
        "player": {"name": name_initial, "firstname": firstname, "lastname": lastname,
                   "photo": "https://example.com/p.png"},
        "statistics": [{
            "team": {"name": team},
            "games": {"appearences": appearances, "position": position},
            "goals": {"total": goals, "assists": assists},
        }],
    }


def test_fetch_leaderboard_uses_full_name_not_initial(monkeypatch):
    monkeypatch.setattr(api_football, "_get", lambda url, headers: _response(
        _player("E. Haaland", "Erling", "Haaland")))
    rows = api_football.fetch_leaderboard(39, 2023, "scorers", "key")
    assert rows[0].name == "Erling Haaland"


def test_fetch_leaderboard_maps_position_and_stats(monkeypatch):
    monkeypatch.setattr(api_football, "_get", lambda url, headers: _response(
        _player("K. De Bruyne", "Kevin", "De Bruyne", position="Midfielder",
                appearances=32, goals=8, assists=18)))
    row = api_football.fetch_leaderboard(39, 2023, "assists", "key")[0]
    assert row.position == "MF"
    assert row.stats == {"appearances": 32.0, "goals": 8.0, "assists": 18.0}
    assert "clean_sheets" not in row.stats


def test_fetch_leaderboard_drops_defenders_and_keepers(monkeypatch):
    # This source has no clean-sheets field, so a DF/GK row from it would only ever
    # compete in soccer-defenders on goals/assists alone — ranking ahead of genuine
    # clean-sheet specialists who correctly show 0 goals/assists. Must be dropped, not
    # kept with an incomplete stat line.
    monkeypatch.setattr(api_football, "_get", lambda url, headers: _response(
        _player("J. Tavernier", "James", "Tavernier", position="Defender", assists=12),
        _player("Alisson", "Alisson", "Becker", position="Goalkeeper", assists=1),
        _player("H. Kane", "Harry", "Kane", position="Attacker", goals=30)))
    rows = api_football.fetch_leaderboard(39, 2023, "assists", "key")
    assert [r.name for r in rows] == ["Harry Kane"]


def test_fetch_leaderboard_derives_short_code_from_multiword_team(monkeypatch):
    monkeypatch.setattr(api_football, "_get", lambda url, headers: _response(
        _player("H. Kane", "Harry", "Kane", team="Manchester City")))
    row = api_football.fetch_leaderboard(39, 2023, "scorers", "key")[0]
    assert row.team_abbr == "MC"


def test_fetch_leaderboard_skips_player_with_no_appearances(monkeypatch):
    monkeypatch.setattr(api_football, "_get", lambda url, headers: _response(
        _player("Nobody", "No", "Body", appearances=0)))
    assert api_football.fetch_leaderboard(39, 2023, "scorers", "key") == []


def test_fetch_leaderboard_soft_error_returns_empty_not_raises(monkeypatch):
    def fake(url, headers):
        return {"errors": {"plan": "Free plans do not have access to this season"},
                "response": []}, {}
    monkeypatch.setattr(api_football, "_get", fake)
    assert api_football.fetch_leaderboard(39, 2010, "scorers", "key") == []


def _season(name, year, team, **stats):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport="soccer",
                     position="FW", stats=stats, source="seed")


def test_merge_with_seed_prefers_live_for_exact_same_player_season():
    # Team codes AND full names deliberately differ (seed's hand-typed 3-letter code and
    # casual name vs live's name-derived initials and api-football's full legal name,
    # e.g. "Erling Braut Haaland") — this must dedup on (last name, season_year), or the
    # stale seed row wrongly survives as a near-duplicate.
    live = [_season("Erling Braut Haaland", 2023, "MC", goals=27)]
    seed_rows = [_season("Erling Haaland", 2023, "MCI", goals=36),  # stale seed duplicate
                 _season("Petr Cech", 2005, "CHE", clean_sheets=24)]  # live can't cover this
    merged = api_football.merge_with_seed(live, seed_rows)
    assert len(merged) == 2
    haaland = next(r for r in merged if "Haaland" in r.name)
    assert haaland.stats["goals"] == 27  # live wins, not the stale seed value
    assert any(r.name == "Petr Cech" for r in merged)


def test_season_window_is_last_four_years_before_today():
    import datetime as dt
    window = api_football._season_window(dt.date(2026, 7, 7))
    assert window == [2022, 2023, 2024, 2025]
