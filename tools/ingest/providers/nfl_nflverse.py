"""NFL provider — real season stats from nflverse public data (no API key).

Uses the pre-aggregated `player_stats_season_{year}.csv` release assets from
https://github.com/nflverse/nflverse-data/releases/tag/player_stats, which
already sum each player's regular/post/combined season. We take regular-season
(`season_type == 'REG'`) rows. Coverage is 1999-present; pre-1999 legends come
from the curated seed instead.
"""
from __future__ import annotations

import csv
import io

from ..models import RawSeason
from .http import fetch_text

_BASE = (
    "https://github.com/nflverse/nflverse-data/releases/download/"
    "player_stats/player_stats_season_{year}.csv"
)

# nflverse-season coverage. Season files exist from 1999 onward.
MIN_YEAR = 1999


def _num(row: dict, key: str) -> float:
    raw = row.get(key, "")
    if raw in ("", "NA", None):
        return 0.0
    try:
        return float(raw)
    except ValueError:
        return 0.0


def fetch_year(year: int, *, ttl_hours: float = 24 * 30) -> list[RawSeason]:
    """All regular-season offensive player-seasons for one year."""
    if year < MIN_YEAR:
        return []
    text = fetch_text(
        _BASE.format(year=year),
        cache_key=f"nflverse_season_{year}.csv",
        ttl_hours=ttl_hours,
    )
    seasons: list[RawSeason] = []
    for row in csv.DictReader(io.StringIO(text)):
        if row.get("season_type") != "REG":
            continue
        pos = (row.get("position") or "").upper()
        if pos not in {"QB", "RB", "WR", "TE", "FB"}:
            continue
        games = _num(row, "games")
        carries = _num(row, "carries")
        receptions = _num(row, "receptions")
        rush_yards = _num(row, "rushing_yards")
        rec_yards = _num(row, "receiving_yards")
        attempts = _num(row, "attempts")
        completions = _num(row, "completions")
        stats = {
            "games": games,
            "passing_yards": _num(row, "passing_yards"),
            "passing_tds": _num(row, "passing_tds"),
            "interceptions": _num(row, "interceptions"),
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
        seasons.append(
            RawSeason(
                name=row.get("player_display_name") or row.get("player_name") or "",
                team_abbr=row.get("recent_team") or "",
                season_year=year,
                sport="nfl",
                position=pos,
                stats=stats,
                source="nflverse",
                headshot=row.get("headshot_url") or "",
                # gsis id (= players.csv key) so the bio join in main.py is collision-free.
                meta={"gsis_id": row.get("player_id") or ""},
            )
        )
    return seasons


def fetch_years(years: list[int]) -> list[RawSeason]:
    out: list[RawSeason] = []
    for year in years:
        try:
            out.extend(fetch_year(year))
        except Exception as err:  # noqa: BLE001 - one bad year shouldn't sink the run
            print(f"[nflverse] skipping {year}: {err}")
    return out
