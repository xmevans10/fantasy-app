"""NBA provider — real season averages from ESPN's public JSON endpoints.

Keyless and historical (2003-04 → present), so it needs no API key and isn't
rate-limited the way balldontlie's free tier is. Two calls per *player* (not per
season): search name → athlete id, then one stats call that returns every season
the player has, which we slice by year. Endpoints are ESPN's undocumented public
API (the same data espn.com renders) — stable in practice, but kept behind a seed
fallback in `main.py` so the pipeline never hard-fails if ESPN changes shape.

Goes through `providers.http.fetch_json` for the shared on-disk cache + the 429
backoff, so repeated/CI runs don't refetch and transient throttling self-heals.
"""
from __future__ import annotations

import time
import urllib.parse

from ..models import RawSeason, slug
from .http import fetch_json

_SEARCH = "https://site.web.api.espn.com/apis/search/v2"
_STATS = "https://site.web.api.espn.com/apis/common/v3/sports/basketball/nba/athletes/{id}/stats"

# ESPN is keyless and generous; a small pause between players is courtesy, not necessity.
_RATE_DELAY = 0.3


def available() -> bool:
    return True  # no key required


def _search_athlete_id(name: str) -> str | None:
    """Resolve a player name to an ESPN athlete id (the `a:<id>` part of its uid)."""
    q = urllib.parse.quote(name)
    data = fetch_json(f"{_SEARCH}?query={q}&limit=10",
                      cache_key=f"espn_nba_search_{slug(name)}.json")
    candidates: list[tuple[str, str]] = []  # (displayName, id)
    for group in data.get("results", []):
        if group.get("type") != "player":
            continue
        for c in group.get("contents", []):
            if c.get("sport") != "basketball":
                continue
            uid = c.get("uid", "")
            aid = next((part[2:] for part in uid.split("~") if part.startswith("a:")), None)
            if aid:
                candidates.append((c.get("displayName", ""), aid))
    if not candidates:
        return None
    # Prefer an exact name match; otherwise the top basketball hit.
    for disp, aid in candidates:
        if disp.lower() == name.lower():
            return aid
    return candidates[0][1]


def _attempted(made_attempted: str) -> float:
    """Parse the attempted half of an ESPN 'made-attempted' pair, e.g. '7.9-18.9' → 18.9."""
    try:
        return float(made_attempted.split("-")[1])
    except (IndexError, ValueError):
        return 0.0


def parse_seasons(name: str, data: dict) -> dict[int, RawSeason]:
    """Turn an ESPN athlete-stats payload into `{season_year: RawSeason}` (end-year keyed).

    Pure (no network) so it's unit-testable. When a season appears more than once
    (traded mid-year), the row with the most games played wins.
    """
    teams = data.get("teams", {})  # keyed by team slug
    averages = next((c for c in data.get("categories", []) if c.get("name") == "averages"), None)
    if not averages:
        return {}
    names = averages.get("names", [])
    out: dict[int, RawSeason] = {}
    for row in averages.get("statistics", []):
        year = (row.get("season") or {}).get("year")
        if not year:
            continue
        v = {k: val for k, val in zip(names, row.get("stats", []))}

        def num(key: str) -> float:
            try:
                return float(v.get(key) or 0)
            except (TypeError, ValueError):
                return 0.0

        ppg = num("avgPoints")
        fga = _attempted(v.get("avgFieldGoalsMade-avgFieldGoalsAttempted", ""))
        fta = _attempted(v.get("avgFreeThrowsMade-avgFreeThrowsAttempted", ""))
        ts = ppg / (2 * (fga + 0.44 * fta)) if (fga + 0.44 * fta) else 0.0
        games = int(num("gamesPlayed"))

        # Multi-team season: keep whichever row has the most games (usually the combined line).
        if year in out and out[year].stats.get("games", 0) >= games:
            continue

        abbr = teams.get(row.get("teamSlug", ""), {}).get("abbreviation", "")
        out[year] = RawSeason(
            name=name,
            team_abbr=abbr,
            season_year=int(year),
            sport="nba",
            position=(row.get("position") or "G").upper(),
            stats={
                "games": games,
                "ppg": ppg,
                "rpg": num("avgRebounds"),
                "apg": num("avgAssists"),
                "spg": num("avgSteals"),
                "bpg": num("avgBlocks"),
                "fg_pct": num("fieldGoalPct") / 100.0,   # ESPN gives percent; store as fraction
                "fg3_pct": num("threePointFieldGoalPct") / 100.0,
                "ts_pct": round(ts, 3),
            },
            source="espn",
        )
    return out


def fetch_player_season(name: str, season_year: int) -> RawSeason | None:
    aid = _search_athlete_id(name)
    if not aid:
        return None
    data = fetch_json(_STATS.format(id=aid), cache_key=f"espn_nba_stats_{aid}.json")
    return parse_seasons(name, data).get(season_year)


def fetch_targets(targets: list[tuple[str, int]]) -> list[RawSeason]:
    """Fetch `(name, season_year)` targets. Grouped by player so each athlete's stats
    are fetched once and sliced for every requested season."""
    by_name: dict[str, list[int]] = {}
    for name, year in targets:
        by_name.setdefault(name, []).append(year)

    out: list[RawSeason] = []
    for name, years in by_name.items():
        try:
            aid = _search_athlete_id(name)
            if not aid:
                print(f"[espn] no athlete match: {name}")
                continue
            seasons = parse_seasons(name, fetch_json(_STATS.format(id=aid),
                                                     cache_key=f"espn_nba_stats_{aid}.json"))
            for year in years:
                if season := seasons.get(year):
                    out.append(season)
                else:
                    print(f"[espn] no {year} season for {name}")
            time.sleep(_RATE_DELAY)
        except Exception as err:  # noqa: BLE001
            print(f"[espn] skipping {name}: {err}")
    return out
