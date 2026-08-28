"""The fresh-drop mint: window modes, the period axis, and the supersede fence.

Synthetic rows only (no network). Where a test needs a period it builds the `Period` directly
rather than going through schedule detection, which `test_periods.py` covers.
"""
from __future__ import annotations

import datetime as dt
import random

import pytest

from tools.ingest import assemble, curation, fresh_drop, generate, periods
from tools.ingest.models import RawSeason
from tools.ingest.themes import Filter, StatColumn, Theme

_COLS = [StatColumn("receiving_yards", "Rec Yds", "comma_int")]


def _game(name, yards, *, week=1, year=2024, date="2024-09-08", team="KC", pos="WR"):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport="nfl", position=pos,
                     stats={"receiving_yards": float(yards), "receptions": 6.0,
                            "receiving_tds": 1.0, "rushing_yards": 0.0, "rushing_tds": 0.0},
                     headshot="h", week=week, opponent="BAL", event_date=date,
                     source="nflverse")


def _theme(**kw):
    base = dict(key="t", title="T", sport="nfl", scale="nfl_skill_ppr_game",
                positions=frozenset({"WR"}), min_stats={}, columns=_COLS, grain="game")
    base.update(kw)
    return Theme(**base)


def _pool(n=20, base=40):
    """`n` game rows with strictly descending yardage, so grades are distinct."""
    return [_game(f"Player {i}", base + (n - i) * 7) for i in range(n)]


# ── event_date is filterable ──────────────────────────────────────────────────

def test_event_date_range_selects_a_window():
    rows = ([_game("In A", 120, date="2024-09-08")] +
            [_game("In B", 110, date="2024-09-09")] +
            [_game("Out Early", 130, date="2024-09-01")] +
            [_game("Out Late", 140, date="2024-09-16")])
    f = Filter("event_date", "range", ("2024-09-05", "2024-09-09"))
    assert [r.name for r in rows if f.matches(r)] == ["In A", "In B"]


def test_a_row_with_no_event_date_never_matches_a_window():
    """Season and career rows carry "", and a period board must never admit one."""
    season_row = RawSeason(name="Seasonal", team_abbr="KC", season_year=2024, sport="nfl",
                           position="WR", stats={"receiving_yards": 1500.0}, headshot="h")
    f = Filter("event_date", "range", ("2024-09-05", "2024-09-09"))
    assert f.matches(season_row) is False


def test_numeric_ranges_still_compare_numerically():
    """Regression guard on the shared `range` op: 9 must be inside 8..10, and a naive string
    compare would say "9" > "10"."""
    row = _game("X", 100, week=9)
    assert Filter("week", "range", (8, 10)).matches(row) is True
    assert Filter("week", "range", (10, 12)).matches(row) is False


# ── Window modes ──────────────────────────────────────────────────────────────

def test_top_mode_returns_exactly_the_best_eight():
    rows = _pool()
    built = assemble.build_keep4_rows(_theme(window_mode="top"), rows, max_variants=5)
    assert len(built) == 1, "'top' is one window by definition"
    names = {p["name"] for p in built[0].content["players"]}
    best_eight = {s.name for s in sorted(rows, key=lambda s: -s.stats["receiving_yards"])[:8]}
    assert names == best_eight


def test_close_mode_is_unchanged_and_is_the_default():
    rows = _pool()
    assert _theme().window_mode == "close"
    default = assemble.build_keep4_rows(_theme(max_variants=3), rows, max_variants=3)
    explicit = assemble.build_keep4_rows(_theme(max_variants=3, window_mode="close"),
                                         rows, max_variants=3)
    assert [r.content["players"] for r in default] == [r.content["players"] for r in explicit]


def test_top_mode_refuses_a_tied_keep_cut_boundary():
    """The clean-boundary rule is not relaxed by 'top' — a board whose 4th and 5th are tied
    has no correct answer, whatever its title says."""
    # The tie must land ON the boundary: sorted by grade the pool reads
    # 200, 190, 180, 170, 170, ... so index 3 and index 4 are equal.
    rows = [_game(f"P{i}", 200 - i * 10) for i in range(3)]
    rows += [_game("Tie A", 170), _game("Tie B", 170)]
    rows += [_game(f"Q{i}", 100 - i * 10) for i in range(4)]
    assert assemble.build_keep4_rows(_theme(window_mode="top"), rows) == []


def test_spread_mode_covers_the_year_range():
    """A franchise ladder must span history rather than cluster in the best era."""
    rows = [_game(f"Player {i}", 1400 - i * 3, year=1990 + i, date=f"{1990 + i}-09-08")
            for i in range(30)]
    close = assemble.build_keep4_rows(_theme(window_mode="close"), rows)
    spread = assemble.build_keep4_rows(_theme(window_mode="spread"), rows)
    assert spread, "spread should build"
    span = lambda row: (max(p["seasonYear"] for p in row.content["players"]) -
                        min(p["seasonYear"] for p in row.content["players"]))
    assert span(spread[0]) > span(close[0])
    # Against the POOL's range, not the raw fixture's: `pool_cap` keeps the top 24 by grade,
    # and in this fixture grade descends with year, so the pool is narrower than the input.
    graded = assemble.grade_pool(_theme(window_mode="spread"), rows)
    pool_span = max(s.season_year for s, _ in graded) - min(s.season_year for s, _ in graded)
    assert span(spread[0]) >= pool_span * 0.9


def test_spread_mode_still_ranks_the_card_by_grade():
    rows = [_game(f"Player {i}", 1400 - i * 3, year=1990 + i, date=f"{1990 + i}-09-08")
            for i in range(30)]
    built = assemble.build_keep4_rows(_theme(window_mode="spread"), rows)[0]
    grades = sorted((p["grade"] for p in built.content["players"]), reverse=True)
    assert grades[3] != grades[4], "the keep/cut boundary must stay unambiguous"


# ── Person dedupe ─────────────────────────────────────────────────────────────

def test_one_player_appears_once_by_default():
    rows = [_game("Star", 200 - i * 5, week=i + 1) for i in range(12)]
    rows += [_game(f"Other {i}", 90 - i) for i in range(8)]
    built = assemble.build_keep4_rows(_theme(), rows)
    for row in built:
        names = [p["name"] for p in row.content["players"]]
        assert len(names) == len(set(names))
        assert names.count("Star") <= 1


def test_the_career_ladder_shape_lets_one_player_hold_every_slot():
    rows = [_game("Star", 200 - i * 9, week=i + 1) for i in range(12)]
    built = assemble.build_keep4_rows(
        _theme(dedupe_person=False, filters=(Filter("name", "eq", "Star"),)), rows)
    assert built, "a single-subject ladder should build"
    names = {p["name"] for p in built[0].content["players"]}
    assert names == {"Star"}
    ids = [p["id"] for p in built[0].content["players"]]
    assert len(ids) == len(set(ids)), "eight distinct rows, not the same row eight times"


# ── The period axis ───────────────────────────────────────────────────────────

def test_period_is_the_outermost_axis():
    """Composition order has to stay fixed or one puzzle keys two ways and the theme
    cooldown stops recognising it."""
    assert generate._AXIS_ORDER[0] == "period"


def test_week_slice_filters_on_season_and_week():
    sl = curation.week_slice(2026, 3)
    assert sl.axis == "period"
    assert sl.key == "2026-wk03"
    match = _game("X", 100, week=3, year=2026)
    miss_week = _game("X", 100, week=4, year=2026)
    miss_year = _game("X", 100, week=3, year=2025)
    assert all(f.matches(match) for f in sl.filters)
    assert not all(f.matches(miss_week) for f in sl.filters)
    assert not all(f.matches(miss_year) for f in sl.filters)


def test_a_rolled_theme_gets_the_period_folded_in_front():
    period = periods.Period(sport="nfl", key="2026-wk03", label="2026 Week 3",
                            start="2026-09-17", end="2026-09-21", season_year=2026,
                            slice=curation.week_slice(2026, 3))
    base = _theme(key="gen-wr-all-undrafted", title="Undrafted WR gems")
    out = fresh_drop._with_period(base, period)
    assert out.key == "gen-2026-wk03-wr-all-undrafted"
    assert out.title == "2026 Week 3: undrafted WR gems"
    assert out.filters[:len(period.slice.filters)] == period.slice.filters


def test_two_different_weeks_never_share_a_theme_key():
    """Which is why the 21-day theme cooldown correctly never fires on period themes."""
    base = _theme(key="gen-wr-all-undrafted", title="Undrafted WR gems")
    keys = set()
    for week in range(1, 19):
        period = periods.Period(sport="nfl", key=f"2026-wk{week:02d}",
                                label=f"2026 Week {week}", start="2026-09-17",
                                end="2026-09-21", season_year=2026,
                                slice=curation.week_slice(2026, week))
        keys.add(fresh_drop._with_period(base, period).key)
    assert len(keys) == 18


# ── Flagship themes ───────────────────────────────────────────────────────────

def _nfl_period():
    return periods.Period(sport="nfl", key="2024-wk01", label="2024 Week 1",
                          start="2024-09-05", end="2024-09-09", season_year=2024,
                          slice=curation.week_slice(2024, 1))


def test_flagship_themes_exist_for_every_nfl_cohort():
    themes = fresh_drop.flagship_themes("nfl", _nfl_period())
    titles = {t.title for t in themes}
    assert "2024 Week 1: top WR performances" in titles
    assert "2024 Week 1: top performances" in titles      # the cross-positional one
    assert all(t.window_mode == "top" for t in themes)
    assert all(t.grain == "game" for t in themes)


def test_the_cross_positional_flagship_spans_positions():
    spec = curation.NFL_GAME_POSITIONS["ANY"]
    assert spec.position_set == frozenset({"QB", "RB", "WR", "TE"})
    assert spec.min_stats == {}, (
        "min_stats are ANDed, so any per-stat floor silently zeroes out every position that "
        "does not record that stat")


def test_flagship_themes_carry_the_period_filter():
    """Every flagship starts with the period's own filters. Division boards append theirs
    after, so the period is always the outermost predicate."""
    period_filters = _nfl_period().slice.filters
    for theme in fresh_drop.flagship_themes("nfl", _nfl_period()):
        assert theme.filters[:len(period_filters)] == period_filters


def test_division_flagships_exist_and_are_cross_positional():
    """The reference catalogue's other plain shape: 21% of its titles are a division. They
    also stop a mostly-plain season repeating "top QB performances" every few weeks."""
    themes = fresh_drop.flagship_themes("nfl", _nfl_period())
    divisions = [t for t in themes if ", AFC" in t.title or ", NFC" in t.title]
    assert len(divisions) == 8
    assert all(t.positions == curation.NFL_GAME_POSITIONS["ANY"].position_set
               for t in divisions)
    assert len({t.key for t in themes}) == len(themes), "flagship keys must be unique"


def test_flagship_count_gives_a_season_enough_plain_shapes():
    """13 shapes across an 18-week season is the margin that keeps the plain boards from
    reading as a rerun; 5 was not enough."""
    assert len(fresh_drop.flagship_themes("nfl", _nfl_period())) == 13


def test_an_unwired_sport_has_no_flagships():
    period = periods.rolling_week("nba", dt.date(2026, 8, 25))
    assert fresh_drop.flagship_themes("nba", period) == []


# ── Cohort gating ─────────────────────────────────────────────────────────────

def test_game_grain_cohorts_are_hidden_from_the_nightly_mint():
    assert curation.SPORTS["nfl-games"].daily is False
    assert curation.SPORTS["nfl"].daily is True


def test_the_nightly_mint_skips_non_daily_cohorts():
    from tools.ingest import daily_puzzle
    rows = _pool(30)
    pairs = daily_puzzle.build_candidates(rows, None, random.Random(1))
    assert all(not t.key.startswith("fresh-") for t, _ in pairs)
    # The gate is on ROLLED cohorts. The handful of hand-written curated game-grain themes
    # (nfl-game-rb-explosion and friends) predate all of this and stay in the nightly mint;
    # what must not appear is a GENERATED game-grain theme, which only the gated
    # `nfl-games` cohort can produce.
    rolled_game = [t.key for t, _ in pairs
                   if t.grain == "game" and t.key.startswith(("gen-", "gen2-"))]
    assert rolled_game == [], (
        f"the `daily` gate leaked: {rolled_game[:3]}")


# ── The supersede fence ───────────────────────────────────────────────────────

@pytest.mark.parametrize("drop_offset", [-3, -1, 0])
def test_supersede_refuses_today_or_earlier(drop_offset, capsys):
    today = dt.date(2026, 9, 15)
    removed = fresh_drop.supersede(today + dt.timedelta(days=drop_offset), "nfl",
                                   keep_id="x", today=today)
    assert removed == 0
    assert "REFUSING" in capsys.readouterr().out


def test_target_date_is_tomorrow_by_default():
    today = dt.date(2026, 9, 15)
    assert fresh_drop.target_date(today, same_day=False) == dt.date(2026, 9, 16)
    assert fresh_drop.target_date(today, same_day=True) == today


def test_the_default_target_is_always_supersede_eligible():
    """The two rules have to agree: if the default drop date were not strictly in the future,
    every default run would refuse its own supersede."""
    today = dt.date(2026, 9, 15)
    assert fresh_drop.target_date(today, same_day=False) > today
