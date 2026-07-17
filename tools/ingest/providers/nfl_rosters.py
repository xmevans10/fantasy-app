"""Full NFL rosters, 1999-present — nflverse `roster_{year}.csv` (one row per season/team/
player, every position). Closes The Grid's biggest depth gap vs Immaculate Grid: the stats
pipeline only carries QB/RB/WR/TE/FB with qualifying stat lines (`nfl_nflverse.fetch_year`'s
position filter), so DBs, linemen, kickers, and cup-of-coffee players were unanswerable even
when factually correct for a team x decade cell.

Feeds ONLY `grid.py`'s valid-answer pools (`extra_members`) — never `player_seasons` — so
Keep4/Draft & Spin/WhoAmI candidate pools are untouched. Validity-only by design: any named
roster row counts (active, IR, practice squad …), because a generous "yes that counts" is the
Immaculate Grid feel and a false accept is far less painful than rejecting a real player.
"""
from __future__ import annotations

import csv
import io
from dataclasses import dataclass

from .http import fetch_text

_BASE = "https://github.com/nflverse/nflverse-data/releases/download/rosters/roster_{year}.csv"
# Roster files exist from 1999 onward (same floor as the season aggregates).
MIN_YEAR = 1999


@dataclass(frozen=True)
class RosterMember:
    name: str
    team_abbr: str
    season_year: int


def fetch_year(year: int, *, ttl_hours: float = 24 * 30) -> list[RosterMember]:
    """Every named (player, team) roster membership for one season, deduped."""
    if year < MIN_YEAR:
        return []
    text = fetch_text(_BASE.format(year=year),
                      cache_key=f"nfl_roster_{year}.csv", ttl_hours=ttl_hours)
    seen: set[tuple[str, str]] = set()
    members: list[RosterMember] = []
    for row in csv.DictReader(io.StringIO(text)):
        name = (row.get("full_name") or "").strip()
        team = (row.get("team") or "").strip()
        if not name or not team:
            continue
        key = (name, team)
        if key in seen:
            continue
        seen.add(key)
        members.append(RosterMember(name=name, team_abbr=team, season_year=year))
    return members


def fetch_years(years: list[int]) -> list[RosterMember]:
    out: list[RosterMember] = []
    for year in years:
        try:
            out.extend(fetch_year(year))
        except Exception as err:  # noqa: BLE001 - one bad year (e.g. unpublished) shouldn't sink the run
            print(f"[nfl-rosters] skipping {year}: {err}")
    return out
