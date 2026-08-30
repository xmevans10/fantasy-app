"""NFL single-game provider — real weekly game logs from nflverse public data (no key).

Uses the `stats_player_week_{year}.csv` release assets (same `player_stats` release as the
season files, weekly grain). Each row is one player's one game; we emit it as a RawSeason
with `week`/`opponent` set so the rest of the pipeline (grade → assemble → validate) treats
it like any other graded entity, just at game grain. Regular season only.

Column note: the weekly file names interceptions `passing_interceptions` (the season file
uses `interceptions`) — remapped here so the grade scales/columns line up.
"""
from __future__ import annotations

import csv
import io

from ..models import RawSeason
from . import nfl_nflverse_schedule
from .http import fetch_text
from .nfl_nflverse import _num

# The `stats_player` release, NOT the legacy `player_stats` one this used to read.
#
# nflverse restructured after the 2024 season and `nfl_nflverse.py` (season grain) already
# handles that with a 2025+ cutover; the weekly grain never got the same treatment, so every
# run logged "[nfl-games] 2025 skipped: HTTP Error 404" and moved on. Probing both tags across
# 1999-2026 showed the fix is simpler than a cutover: `stats_player` serves EVERY year, while
# `player_stats` is missing 2019 as well as 2025+. One base for all years therefore also closes
# a silent six-year-old hole in 2019, which nobody had connected to the 2025 problem.
#
# Schemas verified identical for 2019, 2024 and 2025: every column this parser reads is
# present in all three.
_BASE = (
    "https://github.com/nflverse/nflverse-data/releases/download/"
    "stats_player/stats_player_week_{year}.csv"
)

MIN_YEAR = 1999
_OFFENSE = {"QB", "RB", "WR", "TE", "FB"}


def fetch_year(year: int, *, ttl_hours: float = 24 * 30,
               gamedays: dict[tuple[str, int], str] | None = None) -> list[RawSeason]:
    """All regular-season offensive *games* for one season year.

    `gamedays` is an optional `{(team, week): ISO date}` join from
    `nfl_nflverse_schedule.gameday_index` — the weekly stats file carries no date of its own,
    so without it these rows have a week but no `event_date`. Optional rather than fetched
    here so a caller pulling many years pays for the schedule file once, not per year.
    """
    if year < MIN_YEAR:
        return []
    text = fetch_text(
        _BASE.format(year=year),
        cache_key=f"nflverse_week_{year}.csv",
        ttl_hours=ttl_hours,
    )
    games: list[RawSeason] = []
    for row in csv.DictReader(io.StringIO(text)):
        if row.get("season_type") != "REG":
            continue
        pos = (row.get("position") or "").upper()
        if pos not in _OFFENSE:
            continue
        carries = _num(row, "carries")
        receptions = _num(row, "receptions")
        rush_yards = _num(row, "rushing_yards")
        rec_yards = _num(row, "receiving_yards")
        attempts = _num(row, "attempts")
        completions = _num(row, "completions")
        stats = {
            "games": 1.0,
            "passing_yards": _num(row, "passing_yards"),
            "passing_tds": _num(row, "passing_tds"),
            "interceptions": _num(row, "passing_interceptions"),   # weekly column name
            "attempts": attempts,
            "completions": completions,
            "completion_pct": round(100 * completions / attempts, 1) if attempts else 0.0,
            "carries": carries,
            "rushing_yards": rush_yards,
            "rushing_tds": _num(row, "rushing_tds"),
            "ypc": round(rush_yards / carries, 1) if carries else 0.0,
            "receptions": receptions,
            "targets": _num(row, "targets"),
            "receiving_yards": rec_yards,
            "receiving_tds": _num(row, "receiving_tds"),
            "ypr": round(rec_yards / receptions, 1) if receptions else 0.0,
        }
        week = int(_num(row, "week"))
        games.append(
            RawSeason(
                name=row.get("player_display_name") or row.get("player_name") or "",
                team_abbr=row.get("team") or "",
                season_year=year,
                sport="nfl",
                position=pos,
                stats=stats,
                source="nflverse",
                headshot=row.get("headshot_url") or "",
                week=week or None,
                opponent=row.get("opponent_team") or "",
                event_date=(gamedays or {}).get((row.get("team") or "", week), ""),
                meta={"gsis_id": row.get("player_id") or ""},
            )
        )
    return games


def fetch_years(years: list[int], *, with_dates: bool = True) -> list[RawSeason]:
    """`with_dates=False` skips the schedule fetch entirely — for callers (and tests) that
    only need stat lines and shouldn't pay for a second network file."""
    schedule_rows: list[dict] = []
    if with_dates and years:
        try:
            schedule_rows = nfl_nflverse_schedule.fetch_rows()
        except Exception as err:  # noqa: BLE001
            # A missing schedule file costs game rows their `event_date` and nothing else;
            # every season/week-based theme still builds. Never fail the whole pull for it.
            print(f"[nfl-games] schedule unavailable, rows will carry no event_date: {err}")
    out: list[RawSeason] = []
    for year in years:
        try:
            gamedays = (nfl_nflverse_schedule.gameday_index(schedule_rows, year)
                        if schedule_rows else None)
            out += fetch_year(year, gamedays=gamedays)
        except Exception as err:  # noqa: BLE001
            print(f"[nfl-games] {year} skipped: {err}")
    return out
