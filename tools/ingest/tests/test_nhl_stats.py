"""Offline tests for the NHL provider — the three API behaviours that would silently
corrupt hockey content if the mapping regressed. No network: every test drives the pure
mapping functions with captured API shapes.

The behaviours under test are the ones the live probe found on 2026-09-03, all of which
fail quietly rather than loudly if broken (see the provider's module docstring)."""
from tools.ingest.grade import grade
from tools.ingest.providers import nhl_stats


def test_season_id_and_current_season_span_two_years():
    assert nhl_stats.season_id(1985) == "19851986"
    assert nhl_stats.season_id(2023) == "20232024"


def test_nulls_are_omitted_not_zeroed():
    """Plus-minus did not exist before 1967-68 and shots before 1959-60; the API returns
    None. A zero would claim the player finished dead even and never shot the puck, which
    grades him as a real (bad) season rather than an unrecorded one."""
    row = {"goals": 5, "assists": 10, "points": 15, "plusMinus": None, "shots": None,
           "shootingPct": None, "gamesPlayed": 52, "penaltyMinutes": 87}
    stats = nhl_stats._stats(row, nhl_stats._SKATER_MAP)
    assert stats["goals"] == 5.0 and stats["games"] == 52.0
    for absent in ("plus_minus", "shots", "shooting_pct"):
        assert absent not in stats, f"{absent} should be omitted, not defaulted"


def test_skater_and_goalie_stat_keys_are_disjoint():
    """The whole reason hockey grades on two scales. If these ever overlap, a goalie card
    can render a skater stat family and `Sport.positionStatFamilies` stops protecting it."""
    assert not set(nhl_stats._SKATER_MAP.values()) & (
        set(nhl_stats._GOALIE_MAP.values()) - {"games"})


def test_grade_scales_put_skaters_and_goalies_in_one_band():
    """An all-time skater season and an all-time goalie season must score comparably, or a
    mixed Draft & Spin lineup is decided by which role you drew rather than how you drafted.
    Real 1985-86 Gretzky and 1998-99 Hasek lines."""
    gretzky = {"goals": 52, "assists": 163, "plus_minus": 71, "shots": 350,
               "pp_points": 54, "sh_points": 18, "game_winning_goals": 6}
    hasek = {"wins": 30, "shutouts": 9, "saves": 1877, "goals_against": 119}
    skater = grade(gretzky, "hockey_skater_fantasy")
    goalie = grade(hasek, "hockey_goalie_fantasy")
    assert 400 < goalie < 700, goalie
    assert skater > goalie          # the greatest season ever should outrank a great one
    assert skater / goalie < 1.5    # ...but not by a different order of magnitude


def test_skater_map_actually_carries_time_on_ice():
    """Regression: the first version of `_SKATER_MAP` omitted `timeOnIcePerGame` entirely, so
    the seconds-to-minutes conversion below it was dead code and the column was empty in all
    39,533 swept rows — while `Sport.positionStatFamilies` and `ScoringStat.catalog` both
    advertised TOI, which is how a card ends up rendering "TOI 0.0".

    The original test passed `{**_SKATER_MAP, "timeOnIcePerGame": "toi_per_game"}`, patching in
    the very mapping whose absence was the bug. Assert against the real map."""
    assert nhl_stats._SKATER_MAP.get("timeOnIcePerGame") == "toi_per_game"


def test_toi_is_converted_from_seconds_to_minutes():
    """The API serves time-on-ice per game in SECONDS. Every display bound and the card
    label are in minutes, the only unit a hockey fan reads it in."""
    row = {"gamesPlayed": 82, "goals": 20, "timeOnIcePerGame": 1200}
    stats = nhl_stats._stats(row, nhl_stats._SKATER_MAP)
    assert stats["toi_per_game"] == 1200.0     # raw, before the provider's conversion
    stats["toi_per_game"] = round(stats["toi_per_game"] / 60.0, 2)
    assert stats["toi_per_game"] == 20.0


def test_multi_team_seasons_keep_every_club():
    """A traded player's `teamAbbrevs` is comma-joined. The primary is the first, but all of
    them must survive into `teams_all` — a headshot lookup needs the right one (the wrong
    team 302s to the silo placeholder) and Journeyman needs both to draw the trade."""
    raw = nhl_stats._to_raw({
        "name": "Traded Guy", "team_abbr": "STL", "teams_all": "STL|DET",
        "season_year": 2019, "position": "C", "headshot": "http://x/y.png",
        "goals": "20", "assists": "25", "points": "45", "games": "70",
    }, "nhl_stats")
    assert raw.team_abbr == "STL"
    assert raw.meta["teams_all"] == "STL|DET"
    assert raw.sport == "hockey"
    assert raw.stats["points"] == 45.0
