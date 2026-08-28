"""The shapes module reaching production, and the slice axes added alongside it.

`shapes.py` is a library of builders; until `daily_puzzle._shape_themes` existed, nothing in
the pipeline ever called it, so none of those boards could appear in the app. These tests are
about the WIRING rather than the builders (test_shapes.py covers those).
"""
from __future__ import annotations

import random

import pytest

from tools.ingest import curation, daily_puzzle, shapes
from tools.ingest.models import RawSeason


def _season(name, pts, *, year=2015, team="KC", pos="RB", sport="nfl"):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport=sport, position=pos,
                     stats={"rushing_yards": float(pts) * 10, "rushing_tds": 5.0,
                            "receptions": 30.0, "receiving_yards": 200.0,
                            "receiving_tds": 1.0, "games": 16.0},
                     headshot="h", source="nflverse")


def _deep_nfl_pool():
    """A pool deep enough to support all three shapes: one long career, one deep roster, and
    one franchise with a wide year span."""
    rows = []
    rows += [_season("Ladder Guy", 120 - i * 3, year=2000 + i) for i in range(14)]
    rows += [_season(f"Mate {i}", 110 - i * 4, year=2020, team="SF",
                     pos=["QB", "RB", "WR", "TE"][i % 4]) for i in range(14)]
    rows += [_season(f"Cowboy {i}", 100 - i * 2, year=1995 + i * 2, team="DAL")
             for i in range(14)]
    return rows


# ── The wiring ────────────────────────────────────────────────────────────────

def test_shape_themes_reach_the_nightly_candidate_set():
    """The regression this file exists for: shapes.py shipping nothing."""
    themes = daily_puzzle._shape_themes(_deep_nfl_pool(), random.Random(1))
    keys = [t.key for t in themes]
    assert any(k.startswith("shape-career-") for k in keys), keys
    assert any(k.startswith("shape-franchise-") for k in keys), keys


def test_shape_themes_are_bounded_per_shape():
    """Unbounded, this would build a board for every player with twelve seasons, which on the
    real catalogue is hundreds and costs more than the rest of the mint together."""
    rows = _deep_nfl_pool()
    rows += [_season(f"Extra {i}", 90 - j, year=2000 + j)
             for i in range(20) for j in range(13)]
    themes = daily_puzzle._shape_themes(rows, random.Random(2))
    careers = [t for t in themes if t.key.startswith("shape-career-")]
    assert len(careers) <= shapes.SUBJECTS_PER_SHAPE


def test_shape_themes_are_deterministic_for_a_given_seed():
    """A mint has to be reproducible: a re-dispatched run for the same day must not pick a
    different subject and mint a different board."""
    rows = _deep_nfl_pool()
    a = [t.key for t in daily_puzzle._shape_themes(rows, random.Random(7))]
    b = [t.key for t in daily_puzzle._shape_themes(rows, random.Random(7))]
    assert a == b


def test_a_sport_with_no_rows_contributes_no_shapes():
    assert daily_puzzle._shape_themes([], random.Random(1)) == []


def test_sports_with_no_unifying_scale_get_no_roster_board():
    """Baseball hitters and pitchers cannot be ranked against each other, and soccer's
    attackers and defenders are scored by different formulas. A roster board there would be
    comparing numbers that do not share a meaning."""
    for sport in ("baseball", "soccer"):
        assert daily_puzzle.SHAPE_COHORTS[sport][2] is None


def test_missing_team_credentials_never_fail_a_mint(monkeypatch):
    """The names lookup is a nicety. A mint that died because Supabase was unreachable would
    trade a cosmetic improvement for the whole night's content."""
    import tools.ingest.upsert as upsert
    monkeypatch.setattr(upsert, "fetch_teams",
                        lambda: (_ for _ in ()).throw(RuntimeError("no credentials")))
    themes = daily_puzzle._shape_themes(_deep_nfl_pool(), random.Random(3))
    assert any(t.key.startswith("shape-") for t in themes)


# ── The new slice axes ────────────────────────────────────────────────────────

@pytest.mark.parametrize("cohort", ["nfl", "nba", "baseball", "baseball-pitchers"])
def test_division_slices_exist_for_the_sports_that_have_divisions(cohort):
    axes = {sl.axis for sl in curation.SPORTS[cohort].slices}
    assert "division" in axes, f"{cohort} has no division axis"


@pytest.mark.parametrize("cohort", ["nfl", "nba", "baseball", "soccer", "tennis"])
def test_every_sport_can_say_active(cohort):
    keys = {sl.key for sl in curation.SPORTS[cohort].slices}
    assert "active" in keys, f"{cohort} cannot express 'Active'"


def test_the_active_window_rolls_with_the_year():
    """A hardcoded year would quietly stop meaning "active" the moment the season turned."""
    a = curation.active_slice(2026).filters[0].value
    b = curation.active_slice(2030).filters[0].value
    assert b - a == 4


def test_division_membership_is_complete_and_disjoint():
    for label, table, expected in (("NFL", curation.NFL_DIVISIONS, 32),
                                   ("NBA", curation.NBA_DIVISIONS, 30),
                                   ("MLB", curation.MLB_DIVISIONS, 30)):
        clubs = [c for teams in table.values() for c in teams]
        assert len(clubs) == expected, f"{label} has {len(clubs)} clubs, expected {expected}"
        assert len(set(clubs)) == len(clubs), f"{label} lists a club in two divisions"


def test_the_nfl_cross_positional_season_spec_is_position_neutral():
    """`min_stats` are ANDed, so any per-stat floor silently zeroes out every position that
    does not record that stat. This is the constraint the curated theme documents."""
    spec = curation.POSITIONS["ANY"]
    assert spec.position_set == frozenset({"QB", "RB", "WR", "TE"})
    assert set(spec.min_stats) == {"games"}
