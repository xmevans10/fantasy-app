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
from .http import fetch_text
from .nfl_nflverse import _num

_BASE = (
    "https://github.com/nflverse/nflverse-data/releases/download/"
    "player_stats/stats_player_week_{year}.csv"
)

MIN_YEAR = 1999
_OFFENSE = {"QB", "RB", "WR", "TE", "FB"}


def fetch_year(year: int, *, ttl_hours: float = 24 * 30) -> list[RawSeason]:
    """All regular-season offensive *games* for one season year."""
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
                meta={"gsis_id": row.get("player_id") or ""},
            )
        )
    return games


def fetch_years(years: list[int]) -> list[RawSeason]:
    out: list[RawSeason] = []
    for year in years:
        try:
            out += fetch_year(year)
        except Exception as err:  # noqa: BLE001
            print(f"[nfl-games] {year} skipped: {err}")
    return out
