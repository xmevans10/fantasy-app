"""Puzzle shapes: arrangements that are not "eight rows matching a predicate".

Synthetic rows only. Each shape gets a test for the thing that makes it a different SHAPE,
not just a different filter, because that distinction is the whole point of the module.
"""
from __future__ import annotations

import pytest

from tools.ingest import assemble, curation, shapes
from tools.ingest.models import RawSeason


def _season(name, pts, *, year=2015, team="KC", pos="RB", sport="nfl"):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport=sport, position=pos,
                     stats={"rushing_yards": float(pts) * 10, "rushing_tds": 5.0,
                            "receptions": 30.0, "receiving_yards": 200.0,
                            "receiving_tds": 1.0, "games": 16.0},
                     headshot="h", source="nflverse")


def _game(name, yards, *, date="2024-09-08", team="KC", opp="BAL", week=1, pos="WR"):
    return RawSeason(name=name, team_abbr=team, season_year=2024, sport="nfl", position=pos,
                     stats={"receiving_yards": float(yards), "receptions": 6.0,
                            "receiving_tds": 1.0, "rushing_yards": 0.0, "rushing_tds": 0.0},
                     headshot="h", week=week, opponent=opp, event_date=date, source="nflverse")


RB = curation.POSITIONS["RB"]


# ── 02 · Career ladder ────────────────────────────────────────────────────────

def test_career_ladder_subjects_needs_enough_seasons():
    rows = [_season("Deep Guy", 100 - i, year=2000 + i) for i in range(12)]
    rows += [_season("Shallow Guy", 90, year=2005)]
    subjects = shapes.career_ladder_subjects(rows, "nfl", RB.position_set, minimum=10)
    assert subjects == ["Deep Guy"]


def test_career_ladder_subjects_ignores_game_and_career_rows():
    """A player with twelve GAMES is not a player with twelve seasons."""
    rows = [_game(f"Gamer", 100, week=i + 1) for i in range(12)]
    assert shapes.career_ladder_subjects(rows, "nfl", frozenset({"WR"}), minimum=10) == []


def test_a_career_ladder_is_one_player_eight_times():
    rows = [_season("Star", 120 - i * 4, year=2000 + i) for i in range(14)]
    rows += [_season("Noise", 200, year=2005)]
    theme = shapes.career_ladder("nfl", "Star", RB)
    built = assemble.build_keep4_rows(theme, rows)
    assert built, "the ladder should build"
    players = built[0].content["players"]
    assert {p["name"] for p in players} == {"Star"}
    assert len({p["id"] for p in players}) == 8, "eight distinct seasons, not one repeated"


def test_a_career_ladder_spans_the_career():
    rows = [_season("Star", 120 - i * 4, year=2000 + i) for i in range(14)]
    built = assemble.build_keep4_rows(shapes.career_ladder("nfl", "Star", RB), rows)[0]
    years = [p["seasonYear"] for p in built.content["players"]]
    assert max(years) - min(years) >= 10, "a ladder clustered in four years is not a ladder"


# ── 03 · One roster ───────────────────────────────────────────────────────────

def _any_season_spec():
    return curation.PositionSpec(
        "ANY", "player", "nfl_fantasy", {}, curation.NFL_GAME_POSITIONS["ANY"].columns,
        members=("QB", "RB", "WR", "TE"), pool_cap=24)


def test_one_roster_subjects_finds_deep_team_seasons():
    rows = [_season(f"P{i}", 100 - i, team="KC", year=2020) for i in range(12)]
    rows += [_season(f"Q{i}", 100 - i, team="SF", year=2020) for i in range(3)]
    subjects = shapes.one_roster_subjects(rows, "nfl", RB.position_set, minimum=10)
    assert subjects == [("KC", 2020)]


def test_one_roster_is_one_team_one_season_many_positions():
    rows = []
    for i, pos in enumerate(["QB", "RB", "WR", "TE"] * 4):
        rows.append(_season(f"KC {i}", 120 - i * 3, team="KC", year=2020, pos=pos))
    rows += [_season(f"SF {i}", 200, team="SF", year=2020, pos="RB") for i in range(8)]
    rows += [_season(f"KC old {i}", 200, team="KC", year=2019, pos="RB") for i in range(8)]
    built = assemble.build_keep4_rows(shapes.one_roster("nfl", "KC", 2020, _any_season_spec()),
                                      rows)
    assert built
    players = built[0].content["players"]
    assert all(p["teamAbbr"] == "KC" for p in players)
    assert all(p["seasonYear"] == 2020 for p in players)


# ── 04 · Franchise ladder ─────────────────────────────────────────────────────

def test_franchise_ladder_subjects_requires_a_wide_span():
    """A club with twelve seasons all inside one decade is a normal board, not a ladder."""
    wide = [_season(f"W{i}", 100 - i, team="DAL", year=1990 + i * 3) for i in range(12)]
    narrow = [_season(f"N{i}", 100 - i, team="JAX", year=2015 + (i % 4)) for i in range(12)]
    subjects = shapes.franchise_ladder_subjects(wide + narrow, "nfl", RB.position_set,
                                                min_span=20, minimum=10)
    assert subjects == ["DAL"]


def test_a_franchise_ladder_spreads_across_eras():
    import dataclasses
    rows = [_season(f"P{i}", 130 - i, team="DAL", year=1990 + i) for i in range(30)]
    theme = shapes.franchise_ladder("nfl", "DAL", RB)
    assert theme.window_mode == "spread"
    ladder = assemble.build_keep4_rows(theme, rows)[0]
    normal = assemble.build_keep4_rows(dataclasses.replace(theme, window_mode="close"), rows)[0]
    span = lambda r: (max(p["seasonYear"] for p in r.content["players"]) -
                      min(p["seasonYear"] for p in r.content["players"]))
    assert span(ladder) > span(normal)


# ── 05 · Same game ────────────────────────────────────────────────────────────

def test_same_game_subjects_collapses_the_two_sides_of_one_fixture():
    """Both halves of one game must be ONE subject. Counting them separately would offer the
    same fixture twice under two names."""
    rows = ([_game(f"KC {i}", 100 - i, team="KC", opp="BAL") for i in range(6)] +
            [_game(f"BAL {i}", 100 - i, team="BAL", opp="KC") for i in range(6)])
    subjects = shapes.same_game_subjects(rows, "nfl", frozenset({"WR"}), minimum=10)
    assert subjects == [("2024-09-08", "BAL", "KC")]


def test_same_game_needs_an_event_date():
    """The shape is impossible without Layer 1: `week` alone cannot identify one fixture."""
    rows = [_game(f"P{i}", 100 - i) for i in range(12)]
    for row in rows:
        object.__setattr__(row, "event_date", "")
    assert shapes.same_game_subjects(rows, "nfl", frozenset({"WR"}), minimum=8) == []


def test_a_same_game_board_holds_only_that_fixture():
    rows = ([_game(f"KC {i}", 120 - i, team="KC", opp="BAL") for i in range(6)] +
            [_game(f"BAL {i}", 118 - i, team="BAL", opp="KC") for i in range(6)] +
            [_game(f"Other {i}", 200, team="SF", opp="LAR", date="2024-09-15") for i in range(8)])
    theme = shapes.same_game("nfl", "2024-09-08", "BAL", "KC",
                             curation.NFL_GAME_POSITIONS["ANY"])
    built = assemble.build_keep4_rows(theme, rows)
    assert built
    assert {p["teamAbbr"] for p in built[0].content["players"]} <= {"KC", "BAL"}


def test_same_game_titles_carry_a_readable_date():
    theme = shapes.same_game("nfl", "2024-09-08", "BAL", "KC",
                             curation.NFL_GAME_POSITIONS["ANY"])
    assert "Sep 8, 2024" in theme.title
    assert "—" not in theme.title and "–" not in theme.title


# ── Bonus · Kit colour ────────────────────────────────────────────────────────

@pytest.mark.parametrize("hex_color,family", [
    ("#0B162A", "blue"),      # Bears navy
    ("#C60C30", "red"),       # Bills red
    ("#006747", "green"),     # Eagles-ish green
    ("#FFB612", "gold"),      # Steelers gold: the reason the orange/gold split is at 36 deg
    ("#FB4F14", "orange"),    # Bengals orange
    ("#4F2683", "purple"),    # Ravens/Vikings purple
    ("#00B2A9", "teal"),      # Dolphins teal
    ("#000000", "black"),
    ("#FFFFFF", "white"),
    ("#A5ACAF", "grey"),
])
def test_colour_families_match_what_a_person_would_say(hex_color, family):
    assert shapes.color_family(hex_color) == family


@pytest.mark.parametrize("bad", ["", "nope", "#12345", "#GGGGGG", None])
def test_unparseable_colours_have_no_family(bad):
    assert shapes.color_family(bad) == ""


def test_merge_team_colors_joins_onto_meta_and_reports_coverage():
    rows = [_season("A", 100, team="CHI"), _season("B", 90, team="KC"),
            _season("C", 80, team="OAK")]      # OAK: a relocated club, absent from `teams`
    teams = [{"sport": "nfl", "team_abbr": "CHI", "primary_color": "#0B162A"},
             {"sport": "nfl", "team_abbr": "KC", "primary_color": "#E31837"}]
    assert shapes.merge_team_colors(rows, teams) == 2
    assert rows[0].meta["color_family"] == "blue"
    assert rows[1].meta["color_family"] == "red"
    assert "color_family" not in rows[2].meta


def test_a_colour_theme_only_admits_joined_rows():
    rows = [_season(f"Blue {i}", 120 - i, team="CHI") for i in range(10)]
    rows += [_season(f"Unjoined {i}", 200, team="OAK") for i in range(10)]
    teams = [{"sport": "nfl", "team_abbr": "CHI", "primary_color": "#0B162A"}]
    shapes.merge_team_colors(rows, teams)
    built = assemble.build_keep4_rows(shapes.color_theme("nfl", "blue", RB), rows)
    assert built
    assert all(p["teamAbbr"] == "CHI" for p in built[0].content["players"])


# ── House style ───────────────────────────────────────────────────────────────

def test_club_names_replace_abbreviations_in_titles():
    """The abbreviation is a database key. A player reads "The 2020 Chiefs"."""
    teams = [{"sport": "nfl", "team_abbr": "KC", "full_name": "Kansas City Chiefs"},
             {"sport": "nfl", "team_abbr": "XXX", "full_name": None},
             {"sport": "nba", "team_abbr": "KC", "full_name": "Kings"}]
    names = shapes.team_names(teams, "nfl")
    assert names["KC"] == "Kansas City Chiefs"
    assert names["XXX"] == "XXX", "a club with no name on file falls back to its abbr"
    spec = _any_season_spec()
    theme = shapes.one_roster("nfl", "KC", 2020, spec, display=names["KC"])
    assert theme.title == "The 2020 Kansas City Chiefs, ranked"
    assert theme.key == "shape-roster-nfl-kc-2020", "the KEY keeps the stable abbreviation"


def test_every_shape_title_is_dash_free():
    spec = _any_season_spec()
    titles = [
        shapes.cross_positional("nfl", spec).title,
        shapes.career_ladder("nfl", "Tom Brady", RB).title,
        shapes.one_roster("nfl", "KC", 2020, spec).title,
        shapes.franchise_ladder("nfl", "DAL", RB).title,
        shapes.same_game("nfl", "2024-09-08", "BAL", "KC", spec).title,
        shapes.color_theme("nfl", "blue", spec).title,
    ]
    for title in titles:
        assert "—" not in title and "–" not in title, title
