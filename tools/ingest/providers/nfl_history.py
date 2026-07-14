"""Historical full-league NFL seasons, 1970–1998 — Pro-Football-Reference-derived yearly
stats via the `fantasydatapros/data` GitHub dataset (one CSV per season, 1970–2021,
every offensive player with the full passing/rushing/receiving line — verified:
O.J. Simpson's 1,817-yard 1975 is in there).

Closes the last NFL gap: nflverse's season aggregates start at 1999 (`nfl_nflverse.py`'s
own documented floor), so the entire 1970–1998 era — Payton, Rice's early years, the
'70s Steelers — had no full-league source. Only rows ≤ `MAX_YEAR` (1998) are taken;
1999+ stays nflverse's (richer columns: targets, headshots, bio joins).

Stat keys mirror `nfl_nflverse.fetch_year` exactly (same grade formulas downstream);
`targets` doesn't exist pre-1999 and is simply absent from the dict rather than faked
as 0. Team abbrs: PFR's 3-letter spellings are folded to the codes the catalog already
uses where it's the same franchise+city (GNB→GB …); era-specific codes (RAI, RAM,
BAL-as-Colts …) pass through — they're real for their years and collide with nothing
(a (team, year) combo is the unit everywhere downstream). "2TM"/"3TM"/"4TM" (traded) → "".

Headshots: Wikipedia top-slice resolution per season by fantasy points (shared
`providers/wikimedia.py`, football-context verified) — same M16 posture as `bref_nba`,
widened to ~100/season (backlog #9) since resolution is cheap and cached. The
theme-pool-eligible slice plus deep-roster Draft & Spin rows now get real photos;
whatever's left past the slice ships with the standard silhouette fallback.

Run:  python -m tools.ingest.providers.nfl_history
"""
from __future__ import annotations

import argparse
import collections
import csv
import io
from pathlib import Path

from ..models import RawSeason
from .http import fetch_text
from .wikimedia import headshot as wiki_headshot

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "nfl_history_seasons.csv"

_SOURCE_URL = "https://raw.githubusercontent.com/fantasydatapros/data/master/yearly/{year}.csv"

MIN_YEAR = 1970
MAX_YEAR = 1998          # 1999+ is nflverse's territory
# Per-season count of top fantasy scorers who get a Wikipedia photo lookup — widened
# from 40 to 100 (backlog #9): resolution is cheap/cached, and 40 was leaving deep-roster
# Draft & Spin rows silhouette-only even though a wider slice never reaches a bundle.
PHOTO_SLICE_PER_YEAR = 100

_POSITIONS = {"QB", "RB", "WR", "TE"}
_ABBR_FIXES = {"GNB": "GB", "KAN": "KC", "NOR": "NO", "NWE": "NE",
               "SDG": "SD", "SFO": "SF", "TAM": "TB", "2TM": "", "3TM": "", "4TM": ""}

CSV_FIELDS = ["name", "team_abbr", "season_year", "position", "games",
              "passing_yards", "passing_tds", "interceptions", "attempts", "completions",
              "completion_pct", "carries", "rushing_yards", "rushing_tds", "ypc",
              "receptions", "receiving_yards", "receiving_tds", "ypr",
              "fantasy_points", "headshot"]


def _num(row: dict, key: str) -> float:
    try:
        return float(row.get(key) or 0)
    except ValueError:
        return 0.0


def parse_year(year: int, text: str) -> list[dict]:
    """One season file → wide CSV rows (pure, unit-testable). The dataset's ambiguous
    short columns (two `Att`s, two `Yds`s) are ignored in favor of its disambiguated
    `PassingYds`/`RushingAtt`/`ReceivingTD`-style columns."""
    out: list[dict] = []
    for row in csv.DictReader(io.StringIO(text)):
        position = (row.get("Pos") or "").strip().upper()
        if position not in _POSITIONS:
            continue
        name = (row.get("Player") or "").strip().rstrip("*+").strip()
        if not name:
            continue
        abbr = (row.get("Tm") or "").strip()
        abbr = _ABBR_FIXES.get(abbr, abbr)
        completions = _num(row, "Cmp")
        attempts = _num(row, "PassingAtt")
        carries = _num(row, "RushingAtt")
        rush_yards = _num(row, "RushingYds")
        receptions = _num(row, "Rec")
        rec_yards = _num(row, "ReceivingYds")
        out.append({
            "name": name, "team_abbr": abbr, "season_year": year, "position": position,
            "games": int(_num(row, "G")),
            "passing_yards": _num(row, "PassingYds"),
            "passing_tds": _num(row, "PassingTD"),
            "interceptions": _num(row, "Int"),
            "attempts": attempts,
            "completions": completions,
            "completion_pct": round(100 * completions / attempts, 1) if attempts else 0.0,
            "carries": carries,
            "rushing_yards": rush_yards,
            "rushing_tds": _num(row, "RushingTD"),
            "ypc": round(rush_yards / carries, 1) if carries else 0.0,
            "receptions": receptions,
            "receiving_yards": rec_yards,
            "receiving_tds": _num(row, "ReceivingTD"),
            "ypr": round(rec_yards / receptions, 1) if receptions else 0.0,
            "fantasy_points": _num(row, "FantasyPoints"),
            "headshot": "",
        })
    return out


def refresh(year_from: int, year_to: int) -> None:
    rows: list[dict] = []
    for year in range(year_from, year_to + 1):
        try:
            text = fetch_text(_SOURCE_URL.format(year=year),
                              cache_key=f"nfl_history_{year}.csv", ttl_hours=24 * 90)
        except Exception as err:  # noqa: BLE001 — one bad year shouldn't sink the sweep
            print(f"[nfl-history] {year}: skipped ({err})")
            continue
        season_rows = parse_year(year, text)
        print(f"[nfl-history] {year}: {len(season_rows)} player-seasons")
        rows += season_rows

    by_year: dict[int, list[dict]] = collections.defaultdict(list)
    for r in rows:
        by_year[r["season_year"]].append(r)
    photo_names: set[str] = set()
    for year_rows in by_year.values():
        year_rows.sort(key=lambda r: r["fantasy_points"], reverse=True)
        photo_names.update(r["name"] for r in year_rows[:PHOTO_SLICE_PER_YEAR])
    print(f"[nfl-history] resolving Wikipedia headshots for {len(photo_names)} top-slice players …")
    shots = {name: wiki_headshot(name, context="football",
                                 title_suffixes=("American football",))
             for name in sorted(photo_names)}
    matched = sum(1 for v in shots.values() if v)
    print(f"[nfl-history] {matched}/{len(photo_names)} matched a real football photo")
    for r in rows:
        r["headshot"] = shots.get(r["name"], "")

    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"[nfl-history] wrote {len(rows)} player-seasons → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """Historical NFL player-seasons from the committed CSV (stdlib-only; empty until the
    one-time refresh runs). `fantasy_points` is the dataset's own convenience column and
    stays out of `stats` — grading uses the same formulas as every other NFL row."""
    if not CSV_PATH.exists():
        return []
    out: list[RawSeason] = []
    stat_keys = ["games", "passing_yards", "passing_tds", "interceptions", "attempts",
                 "completions", "completion_pct", "carries", "rushing_yards", "rushing_tds",
                 "ypc", "receptions", "receiving_yards", "receiving_tds", "ypr"]
    with CSV_PATH.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out.append(RawSeason(
                name=row["name"],
                team_abbr=row["team_abbr"],
                season_year=int(row["season_year"]),
                sport="nfl",
                position=row["position"],
                stats={k: float(row[k]) for k in stat_keys},
                source="pfr",
                headshot=row["headshot"],
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed 1970–1998 NFL sweep")
    ap.add_argument("--from", dest="year_from", type=int, default=MIN_YEAR)
    ap.add_argument("--to", dest="year_to", type=int, default=MAX_YEAR)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
