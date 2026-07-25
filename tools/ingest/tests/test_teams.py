"""Tests for tools/ingest/teams.py — build_teams/build_leagues shape, no network
(`logos.rehost` monkeypatched to a stub) and no pandas."""
from tools.ingest import teams


def test_build_teams_soccer_rows_are_league_qualified_with_hashed_colors(monkeypatch):
    monkeypatch.setattr(teams.logos, "rehost",
                        lambda source_url, key: f"https://cdn.example/{key}" if source_url else None)
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [
        {"team_abbr": "MCI", "league": "England", "full_name": "Manchester City",
         "espn_id": "382", "logo_url": "https://espn.example/mci.png",
         "primary_color": "#6CABDD", "secondary_color": "#1C2C5B"},
    ])
    monkeypatch.setattr(teams, "load_us_colors", lambda: [])

    rows = teams.build_teams()
    assert len(rows) == 1
    row = rows[0]
    assert row["sport"] == "soccer"
    assert row["team_abbr"] == "MCI"
    assert row["league"] == "England"
    assert row["full_name"] == "Manchester City"
    assert row["espn_id"] == "382"
    assert row["primary_color"] == "#6CABDD"
    assert row["secondary_color"] == "#1C2C5B"
    assert row["logo_url"] == "https://cdn.example/soccer/england/mci.png"


def test_build_teams_us_sports_get_empty_league_and_seed_colors(monkeypatch):
    monkeypatch.setattr(teams.logos, "rehost",
                        lambda source_url, key: f"https://cdn.example/{key}" if source_url else None)
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [])
    monkeypatch.setattr(teams, "load_us_colors", lambda: [
        {"sport": "nfl", "team_abbr": "SF", "primary_color": "#AA0000",
         "secondary_color": "#B3995D", "full_name": ""},
        {"sport": "nba", "team_abbr": "BOS", "primary_color": "#007A33",
         "secondary_color": "#BA9653", "full_name": ""},
        {"sport": "baseball", "team_abbr": "NYY", "primary_color": "#0C2340",
         "secondary_color": "#C4CED3", "full_name": ""},
    ])

    rows = teams.build_teams()
    by_sport = {r["sport"]: r for r in rows}
    assert set(by_sport) == {"nfl", "nba", "baseball"}
    for r in by_sport.values():
        assert r["league"] == ""
        assert r["espn_id"] is None
    assert by_sport["nfl"]["team_abbr"] == "SF"
    assert by_sport["nfl"]["primary_color"] == "#AA0000"
    # ESPN's mlb CDN slug (not `baseball`, the pipeline's own sport name) is used for MLB.
    assert by_sport["baseball"]["logo_url"] == "https://cdn.example/baseball/_/nyy.png"


def test_build_teams_skips_tennis_entirely(monkeypatch):
    monkeypatch.setattr(teams.logos, "rehost", lambda source_url, key: None)
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [])
    monkeypatch.setattr(teams, "load_us_colors", lambda: [])
    rows = teams.build_teams()
    assert rows == []
    assert all(r["sport"] != "tennis" for r in rows)


def test_build_teams_handles_a_none_logo_gracefully(monkeypatch):
    monkeypatch.setattr(teams.logos, "rehost", lambda source_url, key: None)
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [
        {"team_abbr": "BRO", "league": "England", "full_name": "Blackburn Rovers",
         "espn_id": "", "logo_url": "", "primary_color": "", "secondary_color": ""},
    ])
    monkeypatch.setattr(teams, "load_us_colors", lambda: [])
    rows = teams.build_teams()
    assert rows[0]["logo_url"] is None
    assert rows[0]["primary_color"] is None
    assert rows[0]["espn_id"] is None


def test_build_leagues_soccer_uses_the_display_name_mapping_with_a_fallback(monkeypatch):
    monkeypatch.setattr(teams.logos, "rehost", lambda source_url, key: None)
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [
        {"team_abbr": "MCI", "league": "England"},
        {"team_abbr": "FLA", "league": "Brazil"},
        {"team_abbr": "XYZ", "league": "Some Obscure Country"},
    ])
    rows = teams.build_leagues()
    by_league = {r["league"]: r for r in rows if r["sport"] == "soccer"}
    assert by_league["England"]["display_name"] == "Premier League"
    assert by_league["Brazil"]["display_name"] == "Brasileirão"
    assert by_league["Some Obscure Country"]["display_name"] == "Some Obscure Country"


def test_build_leagues_includes_the_three_us_leagues_with_empty_league_code(monkeypatch):
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [])
    monkeypatch.setattr(teams.logos, "rehost", lambda source_url, key: f"https://cdn.example/{key}")

    rows = teams.build_leagues()
    by_sport = {r["sport"]: r for r in rows}
    assert set(by_sport) == {"nfl", "nba", "baseball"}
    assert by_sport["nfl"] == {"sport": "nfl", "league": "", "display_name": "NFL",
                              "logo_url": "https://cdn.example/nfl/_leagues/_.png"}
    assert by_sport["nba"]["display_name"] == "NBA"
    assert by_sport["baseball"]["display_name"] == "MLB"
