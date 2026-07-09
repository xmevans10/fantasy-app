"""NBA full-league season stats — hoopR (sportsdataverse) parquet releases.

Closes M18's NBA coverage gap: `espn_nba_pool` only ever discovers ~850 stat-*leader*
stars, so bench/role players were systematically missing and Draft & Spin team-year
rosters topped out at ~10 players (real NBA rosters carry ~17). hoopR's data repo
(https://github.com/sportsdataverse/hoopR-nba-data) republishes ESPN's own
player-season averages for **every player who appeared in a season** (~530/season),
2002 → present, as one parquet file per season — the NBA equivalent of the nflverse
releases the NFL provider already uses. Pre-2002 seasons have no full-league file;
those years stay covered by the star pool alone (a documented ceiling, not a bug).

Same split as `espn_nba_pool`: a heavyweight refresh path and a stdlib runtime path.

- **Refresh** (occasional; needs `pyarrow`, imported lazily):
  `python -m tools.ingest.providers.hoopr_nba [--from 2002 --to <current year>]`
  downloads each season's parquet, pivots the long (player, stat) rows into one row
  per player-season, and writes the committed `data/nba_hoopr_seasons.csv`.
- **Runtime** (`load_seasons()`): reads that committed CSV with the stdlib `csv`
  module — the daily pipeline never needs pyarrow (see requirements.txt's contract).

The stat vocabulary in these files is ESPN's own (`avgPoints`,
`avgFieldGoalsMade-avgFieldGoalsAttempted`, …), so normalization reuses
`espn_nba`'s helpers — the derived stats (`ts_pct` especially) are guaranteed to
match what the live ESPN path computes for the same player-season.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
from pathlib import Path

from ..models import RawSeason
from .espn_nba import _HEADSHOT, _attempted, _norm_position

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "nba_hoopr_seasons.csv"

_PARQUET_URL = (
    "https://raw.githubusercontent.com/sportsdataverse/hoopR-nba-data/main/"
    "nba/player_season_stats/parquet/player_season_stats_{year}.parquet"
)

# hoopR's player_season_stats files start at 2002 (the 2001-02 season).
MIN_YEAR = 2002

CSV_FIELDS = ["name", "athlete_id", "team_abbr", "season_year", "position",
              "games", "ppg", "rpg", "apg", "spg", "bpg", "fg_pct", "fg3_pct", "ts_pct"]

# ESPN team slug → the abbreviation the catalog already uses (verified against both
# ESPN's live teams API and the live `player_seasons` table's distinct abbrs). Static
# rather than fetched so the refresh has no extra live dependency; `_pivot_season`
# raises on an unknown slug so a future franchise change fails the refresh loudly
# instead of silently dropping a team.
TEAM_SLUG_ABBR: dict[str, str] = {
    "atlanta-hawks": "ATL", "boston-celtics": "BOS", "brooklyn-nets": "BKN",
    "charlotte-hornets": "CHA", "chicago-bulls": "CHI", "cleveland-cavaliers": "CLE",
    "dallas-mavericks": "DAL", "denver-nuggets": "DEN", "detroit-pistons": "DET",
    "golden-state-warriors": "GS", "houston-rockets": "HOU", "indiana-pacers": "IND",
    "la-clippers": "LAC", "los-angeles-lakers": "LAL", "memphis-grizzlies": "MEM",
    "miami-heat": "MIA", "milwaukee-bucks": "MIL", "minnesota-timberwolves": "MIN",
    "new-orleans-pelicans": "NO", "new-york-knicks": "NY", "oklahoma-city-thunder": "OKC",
    "orlando-magic": "ORL", "philadelphia-76ers": "PHI", "phoenix-suns": "PHX",
    "portland-trail-blazers": "POR", "sacramento-kings": "SAC", "san-antonio-spurs": "SA",
    "toronto-raptors": "TOR", "utah-jazz": "UTAH", "washington-wizards": "WSH",
    # Defunct/renamed franchises appearing in 2002+ files, mapped to the same abbrs
    # the existing ESPN-sourced catalog rows already carry for them:
    "new-jersey-nets": "NJ", "seattle-supersonics": "SEA",
    "new-orleans-hornets": "NO", "nooklahoma-city-hornets": "NO",  # ESPN's real slug
    "charlotte-bobcats": "CHA",
}


def _stat_row(name: str, athlete_id: int, abbr: str, year: int, position: str,
              v: dict[str, str]) -> dict | None:
    """One wide CSV row from a player-season's `{stat_name: display_value}` averages.
    Mirrors `espn_nba.parse_seasons`' normalization exactly (percent → fraction,
    true-shooting derived from the made-attempted pairs). None if the position
    doesn't collapse into the catalog's G/F/C buckets."""
    pos = _norm_position(position)
    if not pos:
        return None

    def num(key: str) -> float:
        try:
            return float(v.get(key) or 0)
        except (TypeError, ValueError):
            return 0.0

    ppg = num("avgPoints")
    fga = _attempted(v.get("avgFieldGoalsMade-avgFieldGoalsAttempted", ""))
    fta = _attempted(v.get("avgFreeThrowsMade-avgFreeThrowsAttempted", ""))
    ts = ppg / (2 * (fga + 0.44 * fta)) if (fga + 0.44 * fta) else 0.0
    return {
        "name": name, "athlete_id": athlete_id, "team_abbr": abbr,
        "season_year": year, "position": pos,
        "games": int(num("gamesPlayed")),
        "ppg": ppg, "rpg": num("avgRebounds"), "apg": num("avgAssists"),
        "spg": num("avgSteals"), "bpg": num("avgBlocks"),
        "fg_pct": round(num("fieldGoalPct") / 100.0, 3),
        "fg3_pct": round(num("threePointFieldGoalPct") / 100.0, 3),
        "ts_pct": round(ts, 3),
    }


def _pivot_season(long_rows: list[dict]) -> list[dict]:
    """Pivot one season file's long (player, stat) rows into one CSV row per player.

    A traded player appears under multiple `team_slug` groups plus an "… Totals"
    pseudo-slug; like `espn_nba.parse_seasons`, exactly one row per player-season is
    kept (the ids would collide downstream otherwise): the real-team stint with the
    most games. A player whose ONLY group is "Totals" (traded mid-season with no
    per-stint rows — ~16% of a season file) is kept with an empty team_abbr, matching
    how the live ESPN path already lands traded seasons in the catalog: real for
    Keep4/theme pools, excluded from Draft & Spin spins (which skip empty abbrs)."""
    # (athlete_id, team_slug) → {stat_name: display_value}; athlete_id → identity.
    groups: dict[tuple[int, str], dict[str, str]] = {}
    identity: dict[int, tuple[str, int, str]] = {}  # id → (name, season, position)
    for r in long_rows:
        if r["category"] != "averages":
            continue
        key = (r["athlete_id"], r["team_slug"] or "")
        groups.setdefault(key, {})[r["stat_name"]] = r["display_value"]
        identity[r["athlete_id"]] = (r["athlete_display_name"], r["season"],
                                     r["athlete_position_abbreviation"] or "")

    best: dict[int, tuple[float, str, dict[str, str]]] = {}  # id → (games, slug, stats)
    totals_only: dict[int, dict[str, str]] = {}
    for (aid, slug_), v in groups.items():
        if not slug_ or slug_.endswith("Totals"):
            totals_only.setdefault(aid, v)
            continue
        if slug_ not in TEAM_SLUG_ABBR:
            raise ValueError(f"unknown NBA team slug {slug_!r} — add it to TEAM_SLUG_ABBR")
        try:
            games = float(v.get("gamesPlayed") or 0)
        except ValueError:
            games = 0.0
        if aid not in best or games > best[aid][0]:
            best[aid] = (games, slug_, v)

    out = []
    for aid in sorted(identity):
        if aid in best:
            abbr, v = TEAM_SLUG_ABBR[best[aid][1]], best[aid][2]
        elif aid in totals_only:
            abbr, v = "", totals_only[aid]
        else:
            continue
        name, year, position = identity[aid]
        if row := _stat_row(name, aid, abbr, year, position, v):
            out.append(row)
    return out


def refresh(year_from: int, year_to: int) -> None:
    """Download + pivot every season file in range and write the committed CSV.
    pyarrow is imported lazily so the daily pipeline never needs it (same contract
    as espn_nba_pool's pyespn)."""
    import io
    import urllib.request

    import pyarrow.parquet as pq  # noqa: PLC0415 — heavy/optional, refresh-only

    rows: list[dict] = []
    for year in range(year_from, year_to + 1):
        url = _PARQUET_URL.format(year=year)
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                table = pq.read_table(io.BytesIO(resp.read()))
        except Exception as err:  # noqa: BLE001 — a missing year (e.g. next season) is fine
            print(f"[hoopr] {year}: skipped ({err})")
            continue
        season_rows = _pivot_season(table.to_pylist())
        print(f"[hoopr] {year}: {len(season_rows)} player-seasons")
        rows += season_rows

    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"[hoopr] wrote {len(rows)} player-seasons → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """Full-league NBA player-seasons from the committed CSV (stdlib-only; empty list
    if the sweep hasn't been run — the pipeline then behaves exactly as before M18)."""
    if not CSV_PATH.exists():
        return []
    out: list[RawSeason] = []
    with CSV_PATH.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out.append(RawSeason(
                name=row["name"],
                team_abbr=row["team_abbr"],
                season_year=int(row["season_year"]),
                sport="nba",
                position=row["position"],
                stats={
                    "games": float(row["games"]),
                    "ppg": float(row["ppg"]), "rpg": float(row["rpg"]),
                    "apg": float(row["apg"]), "spg": float(row["spg"]),
                    "bpg": float(row["bpg"]), "fg_pct": float(row["fg_pct"]),
                    "fg3_pct": float(row["fg3_pct"]), "ts_pct": float(row["ts_pct"]),
                },
                source="hoopr",
                headshot=_HEADSHOT.format(id=row["athlete_id"]),
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed hoopR NBA season sweep")
    ap.add_argument("--from", dest="year_from", type=int, default=MIN_YEAR)
    ap.add_argument("--to", dest="year_to", type=int, default=dt.date.today().year)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
