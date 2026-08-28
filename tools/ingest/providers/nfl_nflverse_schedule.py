"""NFL schedule + results provider — nflverse's `schedules/games.csv` release asset.

The weekly STATS file (`nfl_nflverse_games.py`) carries `season`/`week` but **no date and no
result**, so on its own the pipeline cannot answer either question the fresh-drop mint has to
ask: "which week just finished?" and "is it actually finished?". This file answers both. Same
release-asset family and same keyless stdlib fetch as every other nflverse provider here.

Verified live 2026-08-28: 7,548 rows, seasons 1999–2026, columns
`season, game_type, week, gameday, weekday, gametime, away_team, away_score, home_team,
home_score, result, …`. The 2026 regular season is already published (272 games, week 1's
last game 2026-09-14) with every `result` still empty, which is exactly the shape an
unplayed season should have.

`result` is the completion oracle: nflverse populates it only once a game is final, so
"every REG row for (season, week) has a non-empty result" is a true "this week is in the
books" test. It is deliberately stricter than a date compare — a postponed or flexed game
keeps its week open until it is actually played, which is the behaviour a mint wants.
"""
from __future__ import annotations

import csv
import datetime as dt
import io

from .http import fetch_text

_URL = ("https://github.com/nflverse/nflverse-data/releases/download/"
        "schedules/games.csv")

# One file covering every season, rewritten in place as results land. A short TTL is right
# here (unlike the 30-day season files): this is the freshness oracle itself, so caching it
# for a month would mean asking a month-old file whether last night's game is final.
DEFAULT_TTL_HOURS = 3.0


def fetch_rows(*, ttl_hours: float = DEFAULT_TTL_HOURS) -> list[dict]:
    """Every scheduled game, all seasons, raw."""
    text = fetch_text(_URL, cache_key="nflverse_schedules_games.csv", ttl_hours=ttl_hours)
    return list(csv.DictReader(io.StringIO(text)))


def regular_season(rows: list[dict], season: int) -> list[dict]:
    return [r for r in rows if r.get("game_type") == "REG" and _int(r.get("season")) == season]


def _int(value: object) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _is_final(row: dict) -> bool:
    """nflverse leaves `result` empty until a game is played. Guard on the scores too, so a
    source that ever starts writing a placeholder `0` into `result` for unplayed games can't
    silently mark a whole week complete."""
    if not (row.get("result") or "").strip():
        return False
    return bool((row.get("home_score") or "").strip() and (row.get("away_score") or "").strip())


def week_windows(rows: list[dict], season: int) -> dict[int, tuple[str, str]]:
    """`{week: (first_gameday, last_gameday)}` as ISO dates, for that season's regular season.

    The window is what a date-based filter would use; NFL itself filters on the real `week`
    number, but the window is what makes the human label ("Sep 8 to Sep 14") and the
    cross-sport `Period` shape uniform.
    """
    out: dict[int, list[str]] = {}
    for row in regular_season(rows, season):
        week, day = _int(row.get("week")), (row.get("gameday") or "").strip()
        if week is None or not day:
            continue
        out.setdefault(week, []).append(day)
    return {w: (min(days), max(days)) for w, days in sorted(out.items()) if days}


def completed_weeks(rows: list[dict], season: int) -> set[int]:
    """Weeks where EVERY regular-season game has a final result."""
    played: dict[int, list[bool]] = {}
    for row in regular_season(rows, season):
        week = _int(row.get("week"))
        if week is None:
            continue
        played.setdefault(week, []).append(_is_final(row))
    return {w for w, flags in played.items() if flags and all(flags)}


def last_completed_week(rows: list[dict], season: int,
                        as_of: dt.date | None = None) -> int | None:
    """The highest fully-finished regular-season week, or None if the season hasn't produced
    one yet (preseason, week 1 in progress, or a season with no data at all).

    `as_of` bounds the answer to weeks that had actually finished BY that date. Without it a
    completed archive season answers with its final week for every date in the season, so a
    backfill or a replayed run for a Tuesday in December would mint January's week. Live runs
    pass today and are unaffected; it is history and tests that need the bound.
    """
    weeks = completed_weeks(rows, season)
    if as_of is not None:
        windows = week_windows(rows, season)
        weeks = {w for w in weeks
                 if w in windows and dt.date.fromisoformat(windows[w][1]) <= as_of}
    return max(weeks) if weeks else None


def current_season(rows: list[dict], today: dt.date) -> int | None:
    """The season year whose regular season `today` falls inside, or None out of season.

    Derived from the schedule rather than a month heuristic (`Sep <= month <= Jan`), because
    the schedule is the thing that actually knows: it already carries 2026's dates months
    before kickoff, and a heuristic would have to be re-tuned every time the league adds a
    week or moves the opener. A one-week grace period after the final game keeps the
    Tuesday-after-the-last-Sunday drop inside the season it belongs to.
    """
    best: int | None = None
    for season in sorted({s for r in rows if (s := _int(r.get("season"))) is not None}):
        windows = week_windows(rows, season)
        if not windows:
            continue
        opens = min(lo for lo, _ in windows.values())
        closes = max(hi for _, hi in windows.values())
        close_date = dt.date.fromisoformat(closes) + dt.timedelta(days=7)
        if dt.date.fromisoformat(opens) <= today <= close_date:
            best = season
    return best


def gameday_index(rows: list[dict], season: int) -> dict[tuple[str, int], str]:
    """`{(team_abbr, week): gameday}` for one season, both teams of every game.

    This is the join that gives NFL game-grain STAT rows a real date: the weekly stats file
    has `team` and `week` but no date, and every team plays at most once per regular-season
    week, so (team, week) is a unique key into the schedule.
    """
    index: dict[tuple[str, int], str] = {}
    for row in regular_season(rows, season):
        week, day = _int(row.get("week")), (row.get("gameday") or "").strip()
        if week is None or not day:
            continue
        for side in ("home_team", "away_team"):
            team = (row.get(side) or "").strip()
            if team:
                index[(team, week)] = day
    return index
