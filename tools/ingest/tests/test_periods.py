"""Period detection: which competitive window a sport just closed, on its own calendar.

Synthetic schedule rows throughout (no network). The fixture mirrors the real nflverse
`schedules/games.csv` shape verified live 2026-08-28: `season, game_type, week, gameday,
home_team, away_team, home_score, away_score, result`.
"""
from __future__ import annotations

import datetime as dt

import pytest

from tools.ingest import periods
from tools.ingest.providers import nfl_nflverse_schedule as sched


def _game(season, week, gameday, home="KC", away="BAL", final=True):
    return {
        "season": str(season), "game_type": "REG", "week": str(week), "gameday": gameday,
        "home_team": home, "away_team": away,
        "home_score": "27" if final else "", "away_score": "20" if final else "",
        "result": "7" if final else "",
    }


def _season(year, weeks, first_monday="2024-09-05", *, finals=None):
    """`weeks` consecutive weeks, one Thursday + one Monday game each."""
    finals = range(1, weeks + 1) if finals is None else finals
    start = dt.date.fromisoformat(first_monday)
    rows = []
    for wk in range(1, weeks + 1):
        thu = start + dt.timedelta(days=7 * (wk - 1))
        mon = thu + dt.timedelta(days=4)
        for day, home, away in ((thu, "KC", "BAL"), (mon, "SF", "NYJ")):
            rows.append(_game(year, wk, day.isoformat(), home, away, final=wk in finals))
    return rows


# ── The completion oracle ─────────────────────────────────────────────────────

def test_a_week_is_closed_only_when_every_game_is_final():
    rows = _season(2024, 3, finals={1, 2})
    assert sched.completed_weeks(rows, 2024) == {1, 2}


def test_one_unplayed_game_keeps_its_whole_week_open():
    """The postponement case. A date compare would call this week finished; the results
    oracle correctly does not, which is the point of using results at all."""
    rows = _season(2024, 2)
    open_one = [r for r in rows if r["week"] == "2"][0]
    open_one["result"] = ""
    open_one["home_score"] = ""
    open_one["away_score"] = ""
    assert sched.completed_weeks(rows, 2024) == {1}


def test_a_placeholder_result_without_scores_does_not_count_as_final():
    rows = _season(2024, 1)
    rows[0]["home_score"] = ""
    assert sched.completed_weeks(rows, 2024) == set()


def test_last_completed_week_is_bounded_by_as_of():
    """Regression: without the bound, a finished archive season answers with its FINAL week
    for every date inside the season, so replaying a Tuesday in September mints January."""
    rows = _season(2024, 5)
    windows = sched.week_windows(rows, 2024)
    week_2_end = dt.date.fromisoformat(windows[2][1])
    assert sched.last_completed_week(rows, 2024) == 5
    assert sched.last_completed_week(rows, 2024, as_of=week_2_end) == 2


# ── Season boundaries ─────────────────────────────────────────────────────────

def test_out_of_season_returns_none():
    rows = _season(2024, 3)
    assert periods.closed_period("nfl", dt.date(2024, 6, 1), rows) is None


def test_in_season_but_week_one_still_playing_returns_none():
    rows = _season(2024, 3, finals=set())
    assert periods.closed_period("nfl", dt.date(2024, 9, 12), rows) is None


def test_a_published_but_unplayed_future_season_returns_none():
    """Exactly the live 2026 shape: 272 games published, every result empty."""
    rows = _season(2026, 18, first_monday="2026-09-10", finals=set())
    assert periods.closed_period("nfl", dt.date(2026, 9, 20), rows) is None


def test_the_closed_period_advances_week_by_week():
    rows = _season(2024, 4)
    windows = sched.week_windows(rows, 2024)
    for week in (1, 2, 3, 4):
        day_after = dt.date.fromisoformat(windows[week][1]) + dt.timedelta(days=1)
        period = periods.closed_period("nfl", day_after, rows)
        assert period is not None
        assert period.label == f"2024 Week {week}"
        assert period.key == f"2024-wk{week:02d}"


def test_the_period_window_matches_the_schedule():
    rows = _season(2024, 2)
    windows = sched.week_windows(rows, 2024)
    # The day week 1 finished: week 2 is still being played, so week 1 is the closed one.
    period = periods.closed_period("nfl", dt.date.fromisoformat(windows[1][1]), rows)
    assert period.label == "2024 Week 1"
    assert (period.start, period.end) == windows[1]


# ── Rolling windows for the sports with no numbered week ──────────────────────

@pytest.mark.parametrize("today,expected", [
    (dt.date(2026, 8, 25), ("2026-08-17", "2026-08-23")),   # Tuesday
    (dt.date(2026, 8, 24), ("2026-08-17", "2026-08-23")),   # Monday
    (dt.date(2026, 8, 30), ("2026-08-17", "2026-08-23")),   # Sunday, still last week
    (dt.date(2026, 8, 31), ("2026-08-24", "2026-08-30")),   # next Monday, rolls over
])
def test_rolling_week_is_the_last_completed_monday_to_sunday(today, expected):
    period = periods.rolling_week("nba", today)
    assert (period.start, period.end) == expected


def test_rolling_week_never_includes_today():
    """A window that reached into today would mint a puzzle about games still being played."""
    for offset in range(21):
        today = dt.date(2026, 8, 3) + dt.timedelta(days=offset)
        assert periods.rolling_week("nba", today).end < today.isoformat()


def test_window_labels_read_as_words_across_a_month_boundary():
    assert periods.rolling_week("nba", dt.date(2026, 8, 26)).label == "Aug 17 to 23"
    assert periods.rolling_week("nba", dt.date(2026, 9, 8)).label == "Aug 31 to Sep 6"


# ── The wiring gate ───────────────────────────────────────────────────────────

def test_only_nfl_is_wired_today():
    assert periods.WIRED == frozenset({"nfl"})
    assert periods.rolling_week("nba", dt.date(2026, 8, 25)).wired is False


def test_an_unknown_sport_has_no_period():
    assert periods.closed_period("cricket", dt.date(2026, 8, 25)) is None
