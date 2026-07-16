"""NBA single-game provider — hoopR (sportsdataverse) `player_box` parquet releases,
the per-game sibling of `hoopr_nba.py`'s season-average `player_season_stats` files
(same repo, same one-file-per-season shape: `nba/player_box/parquet/player_box_{year}.parquet`).
Each row is one player's one real box score; unlike the season file, `team_abbreviation`/
`opponent_team_abbreviation` and `athlete_headshot_href` are already present per-row in
ESPN's own vocabulary, so no team-slug mapping table is needed here.

Same split as `hoopr_nba.py`: a heavyweight refresh path and a stdlib runtime path.

- **Refresh** (occasional; needs `pyarrow`, imported lazily):
  `python -m tools.ingest.providers.hoopr_nba_games [--from 2015 --to <current year>]`
  downloads each season's parquet, keeps regular-season rows only (`season_type == 2`,
  explicitly excluding the All-Star Game's "EAST"/"WEST" pseudo-teams, which the source
  data also tags `season_type == 2`), and writes the committed `data/nba_hoopr_games.csv`.
- **Runtime** (`load_seasons()`): reads that committed CSV with the stdlib `csv` module —
  the daily pipeline never needs pyarrow (see requirements.txt's contract).

Verified live this session: `player_box_2024.parquet` has 35,028 rows, 32,552 of them
`season_type == 2`; a 40+ point regular-season game happened 164 times in that one
season alone (P.J. Washington's 2024-06-17 line: 4 pts, 6 reb, 3 ast, matching the
public box score).
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
from pathlib import Path

from ..models import RawSeason
from .espn_nba import _HEADSHOT, _norm_position
from .hoopr_nba import MIN_YEAR as SEASON_MIN_YEAR

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "nba_hoopr_games.csv"

_PARQUET_URL = (
    "https://raw.githubusercontent.com/sportsdataverse/hoopR-nba-data/main/"
    "nba/player_box/parquet/player_box_{year}.parquet"
)

# player_box starts the same year player_season_stats does (2002), but full-season
# box-score files are heavier (~35k rows vs ~530) — refresh defaults to a much shorter
# recent window (see main()); the CLI still accepts any --from.
MIN_YEAR = SEASON_MIN_YEAR
DEFAULT_REFRESH_FROM = dt.date.today().year - 10

CSV_FIELDS = ["name", "athlete_id", "team_abbr", "season_year", "position", "opponent_abbr",
              "game_date", "headshot", "points", "rebounds", "assists", "steals", "blocks",
              "field_goals_made", "week"]

# The source data tags the All-Star Game's pseudo-teams `season_type == 2` (regular
# season) alongside real games — exclude explicitly rather than trust the flag alone.
_ALL_STAR_TEAMS = {"EAST", "WEST"}


def _notable(g: dict) -> bool:
    """Whether a game is even plausibly card-worthy for ANY single-game theme (today's
    or a future one) — a generous superset filter, not the tight `min_stats` floor any
    one theme actually grades against. Unlike NFL/MLB's game-grain providers (which fetch
    live per-request and never touch disk beyond the shared HTTP cache), one full NBA
    season is ~26k player-games; committing every single one for 10+ years would make
    this repo's biggest data file by an order of magnitude for no puzzle-relevant gain —
    a Tuesday-in-October 4-point outing can never clear any real theme's floor. Verified
    live this session: this keeps ~11% of a season's rows (2,858 of 26,524 in 2024)."""
    pts = g.get("points") or 0
    reb = g.get("rebounds") or 0
    ast = g.get("assists") or 0
    stl = g.get("steals") or 0
    blk = g.get("blocks") or 0
    return pts >= 25 or reb >= 15 or ast >= 12 or stl >= 5 or blk >= 5 or (reb >= 10 and ast >= 10)


def _game_date_label(value: object) -> str:
    """'2024-06-17' (or a `datetime.date`/`datetime.datetime` — pyarrow's `to_pylist()`
    yields real date objects, not strings) -> 'Jun 17' for the card subtitle (assemble.py's
    `content["gameDate"]`, PlayerSeason.swift's `subtitle`) — pre-formatted here so Swift
    needs no date parsing."""
    if isinstance(value, (dt.date, dt.datetime)):
        d = value
    else:
        try:
            d = dt.date.fromisoformat(str(value)[:10])
        except ValueError:
            return str(value)
    return f"{d.strftime('%b')} {d.day}"


def _pivot_games(long_rows: list[dict]) -> list[dict]:
    """One CSV row per real regular-season player-game, `week` assigned as a 1-based
    sequential index within each player-season (chronological) — the game-grain
    equivalent of `hoopr_nba._pivot_season`'s per-player dedup, just keyed by game
    instead of collapsed to one row."""
    grouped: dict[tuple[int, int], list[dict]] = {}
    for r in long_rows:
        if r.get("season_type") != 2 or r.get("did_not_play"):
            continue
        team_abbr = r.get("team_abbreviation") or ""
        if team_abbr in _ALL_STAR_TEAMS or not team_abbr:
            continue
        pos = _norm_position(r.get("athlete_position_abbreviation") or "")
        if not pos:
            continue
        if not _notable(r):
            continue
        key = (r["athlete_id"], r["season"])
        grouped.setdefault(key, []).append(r)

    out: list[dict] = []
    for (_aid, _season), games in grouped.items():
        games.sort(key=lambda g: g.get("game_date") or "")
        for i, g in enumerate(games, start=1):
            out.append({
                "name": g.get("athlete_display_name") or "",
                "athlete_id": g["athlete_id"],
                "team_abbr": g.get("team_abbreviation") or "",
                "season_year": g["season"],
                "position": _norm_position(g.get("athlete_position_abbreviation") or ""),
                "opponent_abbr": g.get("opponent_team_abbreviation") or "",
                "game_date": _game_date_label(g.get("game_date") or ""),
                "headshot": g.get("athlete_headshot_href") or "",
                "points": g.get("points") or 0,
                "rebounds": g.get("rebounds") or 0,
                "assists": g.get("assists") or 0,
                "steals": g.get("steals") or 0,
                "blocks": g.get("blocks") or 0,
                "field_goals_made": g.get("field_goals_made") or 0,
                "week": i,
            })
    return out


def refresh(year_from: int, year_to: int) -> None:
    """Download + pivot every season file in range and write the committed CSV.
    pyarrow is imported lazily so the daily pipeline never needs it (same contract
    as hoopr_nba.refresh)."""
    import io
    import urllib.request

    import pyarrow.parquet as pq  # noqa: PLC0415 — heavy/optional, refresh-only

    rows: list[dict] = []
    for year in range(year_from, year_to + 1):
        url = _PARQUET_URL.format(year=year)
        try:
            with urllib.request.urlopen(url, timeout=120) as resp:
                table = pq.read_table(io.BytesIO(resp.read()))
        except Exception as err:  # noqa: BLE001 — a missing year (e.g. next season) is fine
            print(f"[hoopr-games] {year}: skipped ({err})")
            continue
        season_rows = _pivot_games(table.to_pylist())
        print(f"[hoopr-games] {year}: {len(season_rows)} player-games")
        rows += season_rows

    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"[hoopr-games] wrote {len(rows)} player-games → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """Single-game NBA player-games from the committed CSV (stdlib-only; empty list if
    the sweep hasn't been run — the pipeline then simply has no NBA game-grain rows)."""
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
                    "points": float(row["points"]), "rebounds": float(row["rebounds"]),
                    "assists": float(row["assists"]), "steals": float(row["steals"]),
                    "blocks": float(row["blocks"]),
                    "field_goals_made": float(row["field_goals_made"]),
                },
                source="hoopr_games",
                headshot=row["headshot"] or _HEADSHOT.format(id=row["athlete_id"]),
                week=int(row["week"]),
                opponent=row["opponent_abbr"],
                game_date=row["game_date"],
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed hoopR NBA single-game sweep")
    ap.add_argument("--from", dest="year_from", type=int, default=DEFAULT_REFRESH_FROM)
    ap.add_argument("--to", dest="year_to", type=int, default=dt.date.today().year)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
