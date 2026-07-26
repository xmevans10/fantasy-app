"""Tests for tools/ingest/teams.py — build_teams/build_leagues shape, no network
(`logos.rehost` monkeypatched to a stub) and no pandas."""
from unittest.mock import patch

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


def test_build_leagues_soccer_comes_from_the_committed_competition_table(monkeypatch):
    # League identity no longer derives from whichever clubs a sweep happened to land — it reads
    # the committed competition table, so a competition with no ingested clubs YET still gets a
    # row (that gap is what rendered a bare "AUSTRALIA" text badge in Draft & Spin).
    monkeypatch.setattr(teams.logos, "rehost", lambda source_url, key: None)
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [])
    monkeypatch.setattr(teams, "load_soccer_leagues", lambda: [
        {"espn_slug": "eng.1", "country": "England", "display_name": "Premier League",
         "tier": 1, "espn_logo_id": "23"},
        {"espn_slug": "ger.2", "country": "Germany", "display_name": "2. Bundesliga",
         "tier": 2, "espn_logo_id": ""},
    ])
    soccer = [r for r in teams.build_leagues() if r["sport"] == "soccer"]
    by_name = {r["display_name"]: r for r in soccer}
    assert by_name["Premier League"]["country"] == "England"
    assert by_name["Premier League"]["tier"] == 1
    # The whole point of the model change: a second division is representable at all.
    assert by_name["2. Bundesliga"]["country"] == "Germany"
    assert by_name["2. Bundesliga"]["tier"] == 2
    assert by_name["2. Bundesliga"]["espn_slug"] == "ger.2"


def test_build_leagues_includes_the_three_us_leagues_with_empty_league_code(monkeypatch):
    monkeypatch.setattr(teams.espn_soccer, "load_team_identity", lambda: [])
    monkeypatch.setattr(teams, "load_soccer_leagues", lambda: [])
    monkeypatch.setattr(teams.logos, "rehost", lambda source_url, key: f"https://cdn.example/{key}")

    rows = teams.build_leagues()
    by_sport = {r["sport"]: r for r in rows}
    assert set(by_sport) == {"nfl", "nba", "baseball"}
    assert by_sport["nfl"] == {"sport": "nfl", "league": "", "display_name": "NFL",
                              "logo_url": "https://cdn.example/nfl/_leagues/_.png",
                              "country": None, "tier": 1, "espn_slug": "nfl"}
    assert by_sport["nba"]["display_name"] == "NBA"
    assert by_sport["baseball"]["display_name"] == "MLB"


def test_load_soccer_leagues_reads_the_real_committed_table():
    # Guards the shipped file itself: every row needs the hierarchy fields a picker groups by,
    # and lower divisions must actually be present (that is the coverage this unlocked).
    rows = teams.load_soccer_leagues()
    assert len(rows) >= 40
    assert all(r["espn_slug"] and r["country"] and r["display_name"] for r in rows)
    assert all(isinstance(r["tier"], int) for r in rows)
    names = {r["display_name"] for r in rows}
    assert {"Premier League", "Bundesliga", "2. Bundesliga", "EFL Championship"} <= names
    assert {r["espn_slug"] for r in rows if r["tier"] > 1} >= {"ger.2", "eng.2"}


def test_build_teams_files_a_club_under_its_own_competition_not_the_top_flight():
    # A 2. Bundesliga club must not be filed under Bundesliga: `teams.competition` is what the
    # app's picker reads to decide a division is selectable, so guessing the nation's top flight
    # would make the lower division both wrong and unreachable.
    identity = [
        {"team_abbr": "SCP", "league": "Germany", "full_name": "SC Paderborn 07",
         "espn_id": "1", "logo_url": "", "primary_color": "", "secondary_color": "",
         "competition": "ger.2"},
        {"team_abbr": "BAY", "league": "Germany", "full_name": "Bayern Munich",
         "espn_id": "2", "logo_url": "", "primary_color": "", "secondary_color": "",
         "competition": "ger.1"},
    ]
    with patch.object(teams.espn_soccer, "load_team_identity", return_value=identity), \
         patch.object(teams.logos, "rehost", return_value=None), \
         patch.object(teams, "load_us_colors", return_value=[]):
        rows = teams.build_teams()
    by_abbr = {r["team_abbr"]: r for r in rows if r["sport"] == "soccer"}
    assert by_abbr["SCP"]["competition"] == "ger.2"
    assert by_abbr["BAY"]["competition"] == "ger.1"
    # Nation stays the same for both — that is exactly why competition had to be stored.
    assert by_abbr["SCP"]["league"] == by_abbr["BAY"]["league"] == "Germany"


def test_build_teams_falls_back_to_the_top_flight_for_a_pre_competition_identity_row():
    identity = [
        {"team_abbr": "BAY", "league": "Germany", "full_name": "Bayern Munich",
         "espn_id": "2", "logo_url": "", "primary_color": "", "secondary_color": ""},
    ]
    with patch.object(teams.espn_soccer, "load_team_identity", return_value=identity), \
         patch.object(teams.logos, "rehost", return_value=None), \
         patch.object(teams, "load_us_colors", return_value=[]):
        rows = teams.build_teams()
    assert next(r for r in rows if r["team_abbr"] == "BAY")["competition"] == "ger.1"
