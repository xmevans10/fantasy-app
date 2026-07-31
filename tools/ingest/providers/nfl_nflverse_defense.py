"""NFL defensive-player provider — closes a real catalog gap: `nfl_nflverse.py` (the
1999-present offense source) hard-filters to `position in {QB,RB,WR,TE,FB}`, so no
defender has ever reached `player_seasons` — Khalil Mack's actual 2016 Defensive Player
of the Year season (11 sacks, career 2014-2022) is nowhere in the app: not searchable in
Grid, not in on-device board generation, not a Keep4/WhoAmI candidate. `nfl_rosters.py`
covers every position but explicitly feeds ONLY `grid.py`'s server-side validity pool
(`extra_members`), never `player_seasons` — a roster row can make a defender "correct" if
guessed, but he's still unsearchable since the real catalog table never has him. This
provider fixes that the normal way: real defensive stat rows into `player_seasons`, same
shape as every other provider.

Same nflverse unified per-player-season release nfl_nflverse.py already reads for 2025+
(`stats_player/stats_player_reg_{year}.csv`, tag `stats_player`) — but unlike the legacy
`player_stats_season_{year}.csv` asset (offense-only), this unified file carries full
defensive columns for every year back to 1999, so it's used here directly for the whole
1999-present span rather than only 2025+.

Filtered on `position_group in {"DL","LB","DB"}` (the robust axis — individual defensive
`position` codes are more varied than offense's, e.g. OLB/MLB/ILB/CB/FS/SS/NT/DE/DT all
collapse into three groups), but `RawSeason.position` keeps the granular code (OLB, CB,
DT, ...) rather than the group, so position-level filters can be added later without a
re-ingest.

Known edge case, intentionally unhandled: `RawSeason.player_id` is `{sport}-{slug(name)}-
{season_year}` with no position component, so a genuine two-way player (offense AND
qualifying defensive stats in the same season) would collide with their own offensive row
from `nfl_nflverse.py` when the two lists are merged in `main.py`. Rare enough in the
modern/legacy stat-line era to accept rather than widen the id scheme for.

Stat key note: `def_fumbles` in the source is NOT fumble recoveries — verified against
nflverse's own field dictionary (`def_fumbles`: "Number of fumbles by this player", i.e.
fumbles the DEFENDER himself committed, extremely rare) and empirically against Khalil
Mack's 2016 row (`def_fumbles=0` despite 3 real recoveries that season). Recoveries live
in separate `fumble_recovery_own`/`fumble_recovery_opp` columns, summed here instead.
"""
from __future__ import annotations

import csv
import io

from ..models import RawSeason
from .http import fetch_text

_BASE = (
    "https://github.com/nflverse/nflverse-data/releases/download/"
    "stats_player/stats_player_reg_{year}.csv"
)

# This unified release's floor — same as nfl_nflverse.py's overall coverage floor.
MIN_YEAR = 1999

_POSITION_GROUPS = {"DL", "LB", "DB"}


def _num(row: dict, key: str) -> float:
    raw = row.get(key, "")
    if raw in ("", "NA", None):
        return 0.0
    try:
        return float(raw)
    except ValueError:
        return 0.0


def fetch_year(year: int, *, ttl_hours: float = 24 * 30) -> list[RawSeason]:
    """All regular-season defensive player-seasons for one year."""
    if year < MIN_YEAR:
        return []
    text = fetch_text(
        _BASE.format(year=year),
        cache_key=f"nflverse_def_season_{year}.csv",
        ttl_hours=ttl_hours,
    )
    seasons: list[RawSeason] = []
    for row in csv.DictReader(io.StringIO(text)):
        if row.get("season_type") != "REG":
            continue
        pos_group = (row.get("position_group") or "").upper()
        if pos_group not in _POSITION_GROUPS:
            continue
        pos = (row.get("position") or "").upper()
        stats = {
            "games": _num(row, "games"),
            "tackles_solo": _num(row, "def_tackles_solo"),
            "tackles_combined": _num(row, "def_tackles_solo") + _num(row, "def_tackles_with_assist"),
            "tackles_for_loss": _num(row, "def_tackles_for_loss"),
            "sacks": _num(row, "def_sacks"),
            "qb_hits": _num(row, "def_qb_hits"),
            # NOT `interceptions` — that key already means "thrown by a QB" on offensive
            # rows; reusing it here would collide/corrupt grading for two-way roster spots.
            "def_interceptions": _num(row, "def_interceptions"),
            "passes_defended": _num(row, "def_pass_defended"),
            "forced_fumbles": _num(row, "def_fumbles_forced"),
            # `def_fumbles` is fumbles committed BY this player (rare) — see module
            # docstring. Actual recoveries are `fumble_recovery_own` + `fumble_recovery_opp`.
            "fumble_recoveries": _num(row, "fumble_recovery_own") + _num(row, "fumble_recovery_opp"),
            "defensive_tds": _num(row, "def_tds"),
            "safeties": _num(row, "def_safeties"),
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
                # gsis id (= players.csv key) so main.py's bio join is collision-free.
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
            print(f"[nflverse-defense] skipping {year}: {err}")
    return out
