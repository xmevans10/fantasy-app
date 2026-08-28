"""House style: no em-dashes (or en-dashes) in anything a player reads.

This is a *content* rule, not a code rule, so it is enforced against the strings the pipeline
actually emits rather than against source files. Comments and docstrings are explicitly out of
scope: they are for whoever is reading the code, and rewriting them would be churn.

The rule exists because the dash had leaked into three different generators independently, and
a convention nobody can check is one that comes back. Live counts when this was written:
565 journeyman rows, 220 Who Am I rows and 7 Keep4 rows in production carried one.
"""
from __future__ import annotations

import random

from tools.ingest import curation, generate, journeyman, periods, themes, whoami_clues
from tools.ingest.models import RawSeason

DASHES = ("—", "–")     # em-dash, en-dash


def _offenders(text: str) -> list[str]:
    return [d for d in DASHES if d in text]


def _assert_clean(label: str, text: str) -> None:
    found = _offenders(text)
    assert not found, f"{label} contains {found!r}: {text!r}"


# ── The title vocabulary every generated theme is built from ──────────────────

def test_curated_theme_titles_are_clean():
    for theme in themes.KEEP4_THEMES:
        _assert_clean(f"curated theme {theme.key}", theme.title)


def test_quirk_titles_are_clean():
    for cohort, cfg in curation.SPORTS.items():
        for quirk in cfg.quirks:
            _assert_clean(f"{cohort} quirk {quirk.key}", quirk.title)
            _assert_clean(f"{cohort} quirk {quirk.key} adjective", quirk.adjective)


def test_slice_affixes_are_clean():
    """Covers the franchise suffix, which is where the dash actually was: every generated
    club theme in production read 'Undrafted WR gems — NYY'."""
    for cohort, cfg in curation.SPORTS.items():
        for sl in cfg.slices:
            _assert_clean(f"{cohort} slice {sl.key}", sl.prefix + sl.suffix)


def test_generated_team_slice_suffixes_are_clean():
    seasons = [RawSeason(name=f"P{i}", team_abbr="NYY", season_year=1995 + i,
                         sport="baseball", position="H", stats={"home_runs": 30.0},
                         headshot="h")
               for i in range(12)]
    for sl in generate.team_slices(curation.SPORTS["baseball"], seasons):
        _assert_clean(f"team slice {sl.key}", sl.prefix + sl.suffix)


# ── Period labels, which are new and go straight into titles ──────────────────

def test_period_labels_and_prefixes_are_clean():
    import datetime as dt
    for sport in ("nba", "baseball", "soccer", "tennis"):
        period = periods.rolling_week(sport, dt.date(2026, 9, 8))   # crosses a month
        _assert_clean(f"{sport} period label", period.label)
        _assert_clean(f"{sport} period prefix", period.slice.prefix)
    week = curation.week_slice(2026, 3)
    _assert_clean("nfl week prefix", week.prefix)


# ── Generated clue and teaser copy ────────────────────────────────────────────

def test_whoami_clue_templates_are_clean():
    """Renders every dimension for a subject populated on every axis, so the templates are
    exercised rather than merely inspected."""
    entry = whoami_clues.WhoAmIEntry(
        sport="nfl", canonical="Test Player", aliases=["Test Player"],
        position="Quarterback", first_year=2005, last_year=2018,
        teams=["Team A", "Team B"], stat_line="40,000 yards", jersey="12",
        fact="won three titles", college="State", college_conference="Big Test",
        height_in=75, weight_lb=225, birth_year=1983, draft_year=2005, draft_round=2,
        draft_pick=40, draft_team="Team A", seasons=14, nickname="The Test",
        accolades=["MVP"], best_season={"year": 2011, "team": "Team A",
                                        "line": "5,000 yards and 40 touchdowns"},
        fame=0.9, source="curated",
    )
    for seed in ("a", "b", "c", "d", "e"):
        for clue in whoami_clues.select_clues(entry, seed=seed):
            _assert_clean("whoami clue", clue.text)


def test_journeyman_teasers_are_clean():
    """Every jab shape, not just one: the separator lives in `fit()`, but the shape decides
    which jab list it joins, and a dash could hide in any of them."""
    entry = whoami_clues.WhoAmIEntry(
        sport="nfl", canonical="Test Player", aliases=[], position="Running back",
        first_year=2010, last_year=2018, teams=["Chargers", "Saints"],
        stat_line="8,000 rushing yards", jersey="21", fact="", seasons=9)
    for clubs in (2, 3, 5, 8):
        stints = [journeyman.Stint(f"T{i}", f"Team {i}", "", 2010 + i, 2011 + i)
                  for i in range(clubs)]
        for truncated in (False, True):
            for seed in ("p1", "p2", "p3"):
                line = journeyman.build_teaser(entry, stints, truncated, seed=seed)
                _assert_clean("journeyman teaser", line)


# ── The composed article: a real generated theme title, end to end ────────────

def test_rolled_theme_titles_are_clean():
    """The composition itself, not just its inputs: prefix + quirk title + suffix is where a
    dash would actually surface."""
    seasons = []
    for i in range(40):
        seasons.append(RawSeason(
            name=f"Player {i}", team_abbr="NYY", season_year=1990 + (i % 30),
            sport="baseball", position="H",
            stats={"home_runs": 20.0 + i, "rbi": 80.0 + i, "avg": 0.280, "ops": 0.850,
                   "runs": 80.0, "hits": 150.0, "slg": 0.500, "obp": 0.360,
                   "doubles": 30.0, "triples": 2.0, "stolen_bases": 10.0,
                   "base_on_balls": 60.0, "games": 150.0},
            headshot="h"))
    rng = random.Random(7)
    cfg = curation.SPORTS["baseball"]
    for _ in range(60):
        theme = generate.roll_theme(cfg, rng, generate.team_slices(cfg, seasons))
        if theme is not None:
            _assert_clean(f"rolled theme {theme.key}", theme.title)
