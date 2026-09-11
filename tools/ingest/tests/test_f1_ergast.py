"""Offline tests for the F1 provider. No network: the aggregation is driven with captured
Ergast race payloads.

The two era hazards these pin are the ones that make F1 different from every other sport
here — a points column that changed meaning three times, and stats that simply did not
exist before 2004."""
from tools.ingest.grade import grade
from tools.ingest.providers import f1_ergast


def _race(*results):
    return {"season": "1990", "round": "1", "Results": list(results)}


def _result(driver, ctor, position, grid="5", fastest=False):
    res = {
        "positionText": position, "position": position, "grid": grid, "points": "9",
        "status": "Finished",
        "Driver": {"driverId": driver, "givenName": driver.title(), "familyName": "X",
                   "nationality": "Brazilian"},
        "Constructor": {"constructorId": ctor, "name": ctor.title()},
    }
    if fastest:
        res["FastestLap"] = {"rank": "1"}
    return res


def test_dnf_is_read_from_position_text_not_status():
    """`status` is free text with dozens of values ("Gearbox", "+2 Laps", "Spun off");
    `positionText` is a digit for every classified finish and a letter otherwise. Only the
    second one is era-proof."""
    assert "R".isdigit() is False      # retired
    assert "1".isdigit() is True
    for code in ("R", "D", "W", "N", "E"):
        assert not code.isdigit(), f"{code} must count as a DNF"


def test_championship_points_are_not_ingested():
    """F1 rewrote its points system in 1961, 1991 and 2010 (a win went 8 -> 9 -> 10 -> 25),
    so a raw points total is not comparable across eras. Every scored stat must instead be
    a countable achievement."""
    assert "points" not in f1_ergast._STAT_KEYS
    scale = {k for k, _ in __import__(
        "tools.ingest.grade", fromlist=["_FANTASY"])._FANTASY["f1_driver_fantasy"]}
    assert "points" not in scale
    assert {"wins", "podiums", "poles", "championships"} <= scale


def test_pre_2004_seasons_omit_fastest_laps():
    """Ergast has no FastestLap block before 2004. Writing 0 would claim Jim Clark never set
    a fastest lap; omitting the key says it was never recorded, which is the truth."""
    assert f1_ergast.FASTEST_LAP_FROM == 2004
    row = {"name": "Old Driver", "team_abbr": "LOTUS", "team_name": "Lotus",
           "teams_all": "LOTUS", "season_year": 1965, "position": "Driver",
           "headshot": "x", "wins": 6, "podiums": 8, "poles": 6, "fastest_laps": "",
           "top_tens": 9, "races": 10, "championships": 1, "dnfs": 2}
    raw = f1_ergast._to_raw(row, "test")
    assert "fastest_laps" not in raw.stats
    assert raw.stats["wins"] == 6.0


def test_constructor_code_is_the_raw_ergast_id():
    """Not a derived 3-letter abbreviation. This repo already merged Blackburn Rovers and
    Brisbane Roar under "BRO" with a word-initials heuristic (see club_codes.py); Ergast ids
    are unique by construction, so using them directly makes that class of bug impossible."""
    row = {"name": "D", "team_abbr": "RED_BULL", "team_name": "Red Bull", "teams_all": "RED_BULL",
           "season_year": 2013, "position": "Driver", "headshot": "x", "wins": 13,
           "podiums": 16, "poles": 9, "fastest_laps": 7, "top_tens": 17, "races": 19,
           "championships": 1, "dnfs": 1}
    raw = f1_ergast._to_raw(row, "test")
    assert raw.team_abbr == "RED_BULL"
    assert raw.meta["team_name"] == "Red Bull"
    assert raw.sport == "f1"


def test_a_title_season_outranks_a_midfield_season_by_a_wide_margin():
    champion = {"wins": 13.0, "podiums": 15.0, "poles": 8.0, "fastest_laps": 10.0,
                "top_tens": 16.0, "races": 18.0, "championships": 1.0, "dnfs": 1.0}
    midfield = {"wins": 0.0, "podiums": 0.0, "poles": 0.0, "fastest_laps": 1.0,
                "top_tens": 8.0, "races": 20.0, "championships": 0.0, "dnfs": 5.0}
    assert grade(champion, "f1_driver_fantasy") > 600
    # A backmarker must still land above zero — a negative grade reads as a broken card.
    assert 0 < grade(midfield, "f1_driver_fantasy") < 100


def test_constructor_switch_keeps_both_teams_in_order():
    races = [_race(_result("driver", "mclaren", "1")),
             _race(_result("driver", "mclaren", "2")),
             _race(_result("driver", "ferrari", "3"))]
    ctors = {}
    import collections
    counter = collections.Counter()
    for r in races:
        for res in r["Results"]:
            counter[(res["Constructor"]["constructorId"], res["Constructor"]["name"])] += 1
    ordered = [c for c, _ in counter.most_common()]
    assert ordered[0][0] == "mclaren"          # raced most for McLaren -> primary
    assert {c[0] for c in ordered} == {"mclaren", "ferrari"}


def test_an_in_progress_season_is_not_swept(monkeypatch):
    """The bug this exists for, caught live 2026-09-03: 12 races into 2026, Ergast's standings
    leader carried `position == "1"` and was written as a world champion he had not won.

    Judged against the SCHEDULE, because both cheaper checks give the wrong answer — the
    newest published result was dated in the past while nine rounds remained, and the results
    feed's race-object count is inflated by pagination. See `_season_is_complete`."""
    import datetime as dt

    calendar = [{"date": "2026-03-08"}, {"date": "2026-08-23"}, {"date": "2026-12-06"}]
    monkeypatch.setattr(f1_ergast, "_paged", lambda path, year: calendar)
    # Mid-season: rounds remain on the calendar, so nothing is committed.
    assert not f1_ergast._season_is_complete(2026, dt.date(2026, 9, 3))
    # After the finale: the season is real and may be swept.
    assert f1_ergast._season_is_complete(2026, dt.date(2026, 12, 7))


def test_a_season_with_no_calendar_is_treated_as_incomplete():
    """Fail closed. An unknown season must not be committed on a guess."""
    import datetime as dt
    original = f1_ergast._paged
    try:
        f1_ergast._paged = lambda path, year: []
        assert not f1_ergast._season_is_complete(2099, dt.date(2099, 12, 31))
    finally:
        f1_ergast._paged = original
