"""NBA provider — real season averages from balldontlie.io (requires API key).

Set BALLDONTLIE_API_KEY (free tier) in the environment. When the key is absent,
`available()` is False and the orchestrator falls back to the curated seed, so
the pipeline still produces real, factual NBA content offline.

Docs: https://docs.balldontlie.io  (v1: /players, /season_averages)
"""
from __future__ import annotations

import os
import time
import urllib.parse

from ..models import RawSeason
from .http import fetch_json

_API = "https://api.balldontlie.io/v1"

# balldontlie's free tier rate-limits aggressively. `fetch_player_season` makes two
# sequential calls (player lookup, then season averages); without spacing them the
# second reliably 429s. Pause between them (the per-target pause in `fetch_targets`
# only spaces *targets*, not the two calls within one).
_INTER_CALL_DELAY = 1.2


def available() -> bool:
    return bool(os.getenv("BALLDONTLIE_API_KEY"))


def _headers() -> dict[str, str]:
    key = os.getenv("BALLDONTLIE_API_KEY")
    if not key:
        raise RuntimeError("BALLDONTLIE_API_KEY not set")
    return {"Authorization": key}


def _find_player(name: str) -> dict | None:
    q = urllib.parse.quote(name)
    data = fetch_json(
        f"{_API}/players?search={q}&per_page=100",
        headers=_headers(),
        cache_key=f"bdl_player_{name.lower().replace(' ', '_')}.json",
    )
    rows = data.get("data", [])
    # Prefer an exact full-name match; otherwise first result.
    for row in rows:
        full = f"{row.get('first_name','')} {row.get('last_name','')}".strip()
        if full.lower() == name.lower():
            return row
    return rows[0] if rows else None


def fetch_player_season(name: str, season_year: int) -> RawSeason | None:
    """Real season averages for one player-season. `season_year` is the end year
    (e.g. 2016 for the 2015-16 season); balldontlie keys seasons by start year."""
    player = _find_player(name)
    if not player:
        return None
    time.sleep(_INTER_CALL_DELAY)  # space the two sequential calls so the second doesn't 429
    start_year = season_year - 1
    data = fetch_json(
        f"{_API}/season_averages?season={start_year}&player_ids[]={player['id']}",
        headers=_headers(),
        cache_key=f"bdl_avg_{player['id']}_{start_year}.json",
    )
    rows = data.get("data", [])
    if not rows:
        return None
    a = rows[0]
    pts, fga, fta = a.get("pts", 0), a.get("fga", 0), a.get("fta", 0)
    # True Shooting %: pts / (2 * (FGA + 0.44 * FTA))
    ts = pts / (2 * (fga + 0.44 * fta)) if (fga + 0.44 * fta) else 0.0
    stats = {
        "games": a.get("games_played", 0),
        "ppg": a.get("pts", 0.0),
        "rpg": a.get("reb", 0.0),
        "apg": a.get("ast", 0.0),
        "spg": a.get("stl", 0.0),
        "bpg": a.get("blk", 0.0),
        "fg_pct": a.get("fg_pct", 0.0),
        "fg3_pct": a.get("fg3_pct", 0.0),
        "ts_pct": round(ts, 3),
    }
    team = player.get("team") or {}
    return RawSeason(
        name=name,
        team_abbr=team.get("abbreviation", ""),
        season_year=season_year,
        sport="nba",
        position=(player.get("position") or "").upper() or "G",
        stats=stats,
        source="balldontlie",
    )


def fetch_targets(targets: list[tuple[str, int]]) -> list[RawSeason]:
    """Fetch a list of (name, season_year) targets, politely rate-limited."""
    out: list[RawSeason] = []
    for name, year in targets:
        try:
            season = fetch_player_season(name, year)
            if season:
                out.append(season)
            time.sleep(1.2)  # respect free-tier rate limits
        except Exception as err:  # noqa: BLE001
            print(f"[balldontlie] skipping {name} {year}: {err}")
    return out
