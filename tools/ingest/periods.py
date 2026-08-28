"""Which competitive period just closed, per sport, on that sport's own calendar.

This is the module that makes "all sports on their own respective schedules" a real thing
rather than a cron comment. Everything else in the fresh-drop path is downstream of one
question: `closed_period(sport, today)` returns a `Period`, or `None`.

`None` is load-bearing in three different ways, all of which mean "do nothing, successfully":
  - the sport is out of season,
  - the sport is in season but the current period is still being played,
  - the sport's event-grain pull is not wired up yet (see `WIRED`).
The fresh-drop job treats all three identically and exits 0, which is why there is no
per-sport season gating to hand-maintain anywhere in the workflows. Compare
weekly-refresh.yml's header, which chose a single all-sport slot precisely to avoid having
to write that gating; this replaces the need for it rather than duplicating it.

Named `periods` and not `calendar` on purpose: `tools.ingest.calendar` would shadow the
stdlib module of that name for anything doing a plain `import calendar` inside this package.
"""
from __future__ import annotations

import dataclasses
import datetime as dt

from . import curation
from .curation import Slice

# Sports whose event-grain data the fresh-drop mint can actually pull today. NFL ships first
# because it is the only sport needing no new box-score provider: nflverse already publishes
# per-week player stats, and the schedule file added alongside this supplies the dates and
# the completion oracle. The rest detect their period fine (the probes below are real) but
# have no game rows to build from until their providers land, so they stay out of this set
# and no-op rather than minting an empty board.
WIRED: frozenset[str] = frozenset({"nfl"})


@dataclasses.dataclass(frozen=True)
class Period:
    """One closed competitive window, and the slice that selects its rows."""
    sport: str
    key: str                 # stable, lands in the theme key: '2026-wk03'
    label: str               # human, lands in the title: '2026 Week 3'
    start: str               # ISO, inclusive
    end: str                 # ISO, inclusive
    season_year: int
    slice: Slice

    @property
    def wired(self) -> bool:
        return self.sport in WIRED


def _last_sunday(today: dt.date) -> dt.date:
    """The most recent Sunday strictly before `today`. `weekday()` is Mon=0..Sun=6."""
    return today - dt.timedelta(days=today.weekday() + 1)


def rolling_week(sport: str, today: dt.date) -> Period:
    """The Monday-to-Sunday week that closed most recently.

    For the sports with no numbered week of their own (NBA and MLB play most nights; their
    `week` field is a per-player sequence index, not a calendar week), a rolling Mon-Sun
    window is the honest unit. Filters on `event_date`, which is exactly why Layer 1 had to
    put a real ISO date on those rows.
    """
    end = _last_sunday(today)
    start = end - dt.timedelta(days=6)
    label = _window_label(start, end)
    return Period(sport=sport, key=f"{start.isoformat()}-to-{end.isoformat()}", label=label,
                  start=start.isoformat(), end=end.isoformat(), season_year=end.year,
                  slice=curation.date_window_slice(start.isoformat(), end.isoformat(), label))


def _window_label(start: dt.date, end: dt.date) -> str:
    """'Aug 18 to 24', or 'Aug 30 to Sep 5' when the window crosses a month. No en- or
    em-dash: house style is that a range reads as words (see curation.py's style note)."""
    left = f"{start.strftime('%b')} {start.day}"
    right = f"{end.day}" if start.month == end.month else f"{end.strftime('%b')} {end.day}"
    return f"{left} to {right}"


def nfl_closed_week(today: dt.date, rows: list[dict] | None = None) -> Period | None:
    """The most recent NFL regular-season week with every game final, or None.

    Deliberately asks the schedule for results rather than comparing dates. A week whose
    Monday night game was postponed is NOT closed, even though its Monday has passed, and a
    puzzle minted off a half-ingested week would be quietly wrong in a way nobody would
    catch. `nfl_nflverse_schedule._is_final` is the oracle.
    """
    from .providers import nfl_nflverse_schedule as sched
    rows = sched.fetch_rows() if rows is None else rows
    season = sched.current_season(rows, today)
    if season is None:
        return None                                   # out of season
    week = sched.last_completed_week(rows, season, as_of=today)
    if week is None:
        return None                                   # in season, week 1 still in progress
    windows = sched.week_windows(rows, season)
    start, end = windows.get(week, ("", ""))
    if not start:
        return None
    return Period(sport="nfl", key=f"{season}-wk{week:02d}", label=f"{season} Week {week}",
                  start=start, end=end, season_year=season,
                  slice=curation.week_slice(season, week))


def closed_period(sport: str, today: dt.date | None = None,
                  nfl_rows: list[dict] | None = None) -> Period | None:
    """The period `sport` most recently finished, or None when there is nothing to mint.

    `nfl_rows` lets a caller pass an already-fetched schedule (tests, and a batch run that
    shouldn't refetch the same file per sport).
    """
    today = today or dt.date.today()
    if sport == "nfl":
        return nfl_closed_week(today, nfl_rows)
    if sport in ("nba", "baseball", "soccer", "tennis"):
        # Real windows, computed the same way for every remaining sport. They return a Period
        # so the shape is testable and the crons are exercisable now; `Period.wired` is what
        # stops the mint acting on one before its provider exists.
        return rolling_week(sport, today)
    return None
