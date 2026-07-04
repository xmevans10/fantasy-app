"""MLB provider — real season stats from the public MLB Stats API.

Keyless and historical (verified live against `statsapi.mlb.com` this session — e.g.
Aaron Judge's 2022 season: 62 HR, .311 AVG, 131 RBI, matching the public record). One
call per player per stat group (hitting/pitching) returns every season at once via
`stats=yearByYear`, mirroring `espn_nba.py`'s "one call, slice by year" shape. Kept
behind a seed fallback in `main.py` since this is a new integration.

Goes through `providers.http.fetch_json` for the shared on-disk cache + 429 backoff.
"""
from __future__ import annotations

import time

from ..models import RawSeason
from .http import fetch_json

_STATS = "https://statsapi.mlb.com/api/v1/people/{id}/stats?stats=yearByYear&group={group}"

# MLB's own image CDN — verified live this session (200 image/jpeg) against Aaron
# Judge's id (592450), the same id `fetch_by_ids` already uses for stats. One current
# headshot per player, not per-season (MLB doesn't serve historical headshots by year).
HEADSHOT_URL = (
    "https://img.mlbstatic.com/mlb-photos/image/upload/"
    "w_213,d_people:generic:headshot:silo:current.png,q_auto:best,f_auto/"
    "v1/people/{id}/headshot/67/current"
)

# MLB team id -> abbreviation (verified against /api/v1/teams?sportId=1).
TEAM_ABBR: dict[int, str] = {
    108: "LAA", 109: "AZ", 110: "BAL", 111: "BOS", 112: "CHC", 113: "CIN", 114: "CLE",
    115: "COL", 116: "DET", 117: "HOU", 118: "KC", 119: "LAD", 120: "WSH", 121: "NYM",
    133: "ATH", 134: "PIT", 135: "SD", 136: "SEA", 137: "SF", 138: "STL", 139: "TB",
    140: "TEX", 141: "TOR", 142: "MIN", 143: "PHI", 144: "ATL", 145: "CWS", 146: "MIA",
    147: "NYY", 158: "MIL",
}

# Rate-limit courtesy, not necessity — MLB's API is keyless and generous.
_RATE_DELAY = 0.2


def available() -> bool:
    return True  # no key required


def _num(stat: dict, key: str) -> float:
    try:
        return float(stat.get(key) or 0)
    except (TypeError, ValueError):
        return 0.0


def _parse_avg(stat: dict, key: str) -> float:
    """MLB reports rate stats (.311) as strings with a leading dot. '.---' means no data."""
    raw = stat.get(key)
    try:
        return float(raw) if raw not in (None, "", ".---") else 0.0
    except (TypeError, ValueError):
        return 0.0


def _parse_innings_pitched(raw: object) -> float:
    """MLB's innings-pitched string ('178.1') encodes THIRDS of an inning in the
    fractional part (.1 = 1/3, .2 = 2/3) — NOT decimal tenths. '178.1' is 178 1/3
    innings (178.33), not 178.1."""
    text = str(raw or "0")
    whole, _, frac = text.partition(".")
    try:
        innings = float(whole or 0)
    except ValueError:
        return 0.0
    thirds = {"0": 0.0, "1": 1 / 3, "2": 2 / 3}.get(frac, 0.0)
    return round(innings + thirds, 3)


def _hitting_row(name: str, split: dict, headshot: str = "") -> RawSeason | None:
    stat = split.get("stat", {})
    year = split.get("season")
    team_id = (split.get("team") or {}).get("id")
    if not year or team_id not in TEAM_ABBR:
        return None
    plate_appearances = _num(stat, "plateAppearances")
    if plate_appearances <= 0:
        return None
    return RawSeason(
        name=name,
        team_abbr=TEAM_ABBR[team_id],
        season_year=int(year),
        sport="baseball",
        position="H",
        stats={
            "plate_appearances": plate_appearances,
            "at_bats": _num(stat, "atBats"),
            "hits": _num(stat, "hits"),
            "doubles": _num(stat, "doubles"),
            "triples": _num(stat, "triples"),
            "home_runs": _num(stat, "homeRuns"),
            "runs": _num(stat, "runs"),
            "rbi": _num(stat, "rbi"),
            "base_on_balls": _num(stat, "baseOnBalls"),
            "stolen_bases": _num(stat, "stolenBases"),
            "avg": _parse_avg(stat, "avg"),
            "obp": _parse_avg(stat, "obp"),
            "slg": _parse_avg(stat, "slg"),
            "ops": _parse_avg(stat, "ops"),
        },
        source="mlb_stats",
        headshot=headshot,
    )


def _pitching_row(name: str, split: dict, headshot: str = "") -> RawSeason | None:
    stat = split.get("stat", {})
    year = split.get("season")
    team_id = (split.get("team") or {}).get("id")
    if not year or team_id not in TEAM_ABBR:
        return None
    innings_pitched = _parse_innings_pitched(stat.get("inningsPitched"))
    if innings_pitched <= 0:
        return None
    return RawSeason(
        name=name,
        team_abbr=TEAM_ABBR[team_id],
        season_year=int(year),
        sport="baseball",
        position="P",
        stats={
            "innings_pitched": innings_pitched,
            "wins": _num(stat, "wins"),
            "losses": _num(stat, "losses"),
            "saves": _num(stat, "saves"),
            "strike_outs": _num(stat, "strikeOuts"),
            "base_on_balls": _num(stat, "baseOnBalls"),
            "earned_runs": _num(stat, "earnedRuns"),
            "era": _parse_avg(stat, "era"),
            "whip": _parse_avg(stat, "whip"),
        },
        source="mlb_stats",
        headshot=headshot,
    )


def parse_seasons(name: str, data: dict, group: str, headshot: str = "") -> list[RawSeason]:
    """Pure (no network) mapper from a `stats=yearByYear` payload to `RawSeason` rows,
    one per season. `group` is 'hitting' or 'pitching' (a two-way player like Ohtani
    needs both, fetched as separate calls — see `fetch_by_ids`). `headshot` is the same
    URL for every season (MLB's CDN only serves a current photo, not one per year)."""
    splits = (data.get("stats") or [{}])[0].get("splits", [])
    parser = _hitting_row if group == "hitting" else _pitching_row
    out: list[RawSeason] = []
    for split in splits:
        # Multi-team ("traded") rows have no numeric team id at the top split level in
        # some payload shapes; skip anything we can't attribute to a real team.
        row = parser(name, split, headshot)
        if row:
            out.append(row)
    return out


def fetch_by_ids(id_to_name: dict[str, str]) -> list[RawSeason]:
    """Fetch every season (hitting AND pitching — a two-way player like Ohtani
    contributes rows to both pools) for each MLB person id."""
    out: list[RawSeason] = []
    for pid, name in id_to_name.items():
        headshot = HEADSHOT_URL.format(id=pid)
        for group in ("hitting", "pitching"):
            try:
                data = fetch_json(_STATS.format(id=pid, group=group),
                                  cache_key=f"mlb_stats_{pid}_{group}.json")
                out += parse_seasons(name, data, group, headshot)
                time.sleep(_RATE_DELAY)
            except Exception as err:  # noqa: BLE001
                print(f"[mlb] skipping id {pid} ({name}, {group}): {err}")
    return out
