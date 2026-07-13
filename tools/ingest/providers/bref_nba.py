"""Historical full-league NBA seasons, 1950–2001 — Basketball-Reference-derived totals
via the `peasant98/TheNBACSV` GitHub dataset (the well-known Kaggle "Seasons_Stats"
lineage: 24,630 player-season rows, 1950–2017, end-year keyed like the rest of our NBA
catalog — verified: Jordan's 3,041-point season carries year 1987).

Closes the last NBA gap: hoopR covers every player 2002+, the ESPN star pool reaches
back to ~1985 for ~850 names, but the full pre-2002 league (the 1950s–1990s benches,
role players, and pre-ESPN-era stars) had no source. Only rows ≤ `MAX_YEAR` (2001) are
taken — 2002+ already comes from hoopR with better freshness and guaranteed headshots.

Headshots: Wikipedia resolution (shared `providers/wikimedia.py`, basketball-context
verified) for the **top slice** of each season by points — widened to ~100/season
(backlog #9) since resolution is cheap and cached (`providers/http.py`'s on-disk cache),
covering deep-roster Draft & Spin rows that used to render silhouette-only. Rows past
the slice still ship photo-less ("" headshot): they exist for Draft & Spin roster depth,
render with the standard silhouette fallback in-app (same precedent as pre-CDN MLB
players), and can't reach a Keep4/WhoAmI bundle because theme pools sort by grade.

Same split as hoopr_nba: refresh (network) → committed `data/nba_bref_seasons.csv`;
runtime `load_seasons()` is stdlib CSV. The dataset is frozen history — no cron needed.

Run:  python -m tools.ingest.providers.bref_nba
"""
from __future__ import annotations

import argparse
import collections
import csv
import io
from pathlib import Path

from ..models import RawSeason
from .espn_nba import _norm_position
from .http import fetch_text
from .wikimedia import headshot as wiki_headshot

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "nba_bref_seasons.csv"

_SOURCE_URL = "https://raw.githubusercontent.com/peasant98/TheNBACSV/master/nbaNew.csv"

MIN_YEAR = 1950
MAX_YEAR = 2001          # 2002+ is hoopR's territory
MIN_GAMES = 10           # a real season, not a 3-game cameo
# Per-season count of top scorers who get a Wikipedia photo lookup — widened from 40 to
# 100 (backlog #9): resolution is cheap/cached, and 40 was leaving deep-roster Draft &
# Spin rows silhouette-only even though a wider slice never reaches a graded theme pool.
PHOTO_SLICE_PER_YEAR = 100

CSV_FIELDS = ["name", "team_abbr", "season_year", "position",
              "games", "ppg", "rpg", "apg", "spg", "bpg", "fg_pct", "fg3_pct", "ts_pct",
              "headshot"]

# Basketball-Reference abbr → the abbr our catalog already uses where it's the same
# franchise+city (pure spelling differences). Era-specific/defunct codes (SYR, STL, BUF,
# KCK, SDC, WSB, CHH, VAN, NJN, SEA …) pass through unchanged — they're real, self-
# consistent, and only exist in years no other source covers. "TOT" (traded) → "".
_ABBR_FIXES = {"GSW": "GS", "PHO": "PHX", "NYK": "NY", "SAS": "SA", "UTA": "UTAH",
               "NOH": "NO", "NOK": "NO", "WAS": "WSH", "BRK": "BKN"}


def _num(row: dict, key: str) -> float:
    raw = (row.get(key) or "").strip().rstrip("%")
    try:
        return float(raw)
    except ValueError:
        return 0.0


def _pct(row: dict, key: str) -> float:
    """BREF percent cells appear both as fractions ('0.539') and as '53.90%' strings."""
    value = _num(row, key)
    return round(value / 100.0, 3) if value > 1.5 else round(value, 3)


def parse_rows(text: str) -> list[dict]:
    """Pivot the raw dataset into our wide CSV rows (headshots resolved separately).
    Pure (no network) so it's unit-testable."""
    out: list[dict] = []
    for row in csv.DictReader(io.StringIO(text)):
        year_raw = (row.get("SeasonStart") or "").strip()
        if not year_raw.isdigit():
            continue
        year = int(year_raw)
        if not (MIN_YEAR <= year <= MAX_YEAR):
            continue
        games = _num(row, "G")
        if games < MIN_GAMES:
            continue
        # "Michael Jordan*" — BREF stars Hall-of-Famers; the suffix is not part of the name.
        name = (row.get("PlayerName") or "").strip().rstrip("*").strip()
        # "PG-SF" style dual positions: the first component is the primary one.
        position = _norm_position((row.get("Pos") or "").split("-")[0])
        if not name or not position:
            continue
        abbr = (row.get("Tm") or "").strip()
        abbr = "" if abbr == "TOT" else _ABBR_FIXES.get(abbr, abbr)
        out.append({
            "name": name, "team_abbr": abbr, "season_year": year, "position": position,
            "games": int(games),
            "ppg": round(_num(row, "PTS") / games, 1),
            "rpg": round(_num(row, "TRB") / games, 1),
            "apg": round(_num(row, "AST") / games, 1),
            "spg": round(_num(row, "STL") / games, 1),
            "bpg": round(_num(row, "BLK") / games, 1),
            "fg_pct": _pct(row, "FG%"),
            "fg3_pct": _pct(row, "3P%"),
            "ts_pct": _pct(row, "TS%"),
            "headshot": "",
        })
    return out


def refresh() -> None:
    text = fetch_text(_SOURCE_URL, cache_key="bref_nba_seasons.csv", ttl_hours=24 * 90)
    rows = parse_rows(text)
    print(f"[bref-nba] {len(rows)} player-seasons {MIN_YEAR}–{MAX_YEAR}")

    # Photo pass for each season's top scorers (the theme-pool/bundle-eligible slice).
    by_year: dict[int, list[dict]] = collections.defaultdict(list)
    for r in rows:
        by_year[r["season_year"]].append(r)
    photo_names: set[str] = set()
    for year_rows in by_year.values():
        year_rows.sort(key=lambda r: r["ppg"] * r["games"], reverse=True)
        photo_names.update(r["name"] for r in year_rows[:PHOTO_SLICE_PER_YEAR])
    print(f"[bref-nba] resolving Wikipedia headshots for {len(photo_names)} top-slice players …")
    shots = {name: wiki_headshot(name, context="basketball",
                                 title_suffixes=("basketball",))
             for name in sorted(photo_names)}
    matched = sum(1 for v in shots.values() if v)
    print(f"[bref-nba] {matched}/{len(photo_names)} matched a real basketball photo")
    for r in rows:
        r["headshot"] = shots.get(r["name"], "")

    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"[bref-nba] wrote {len(rows)} player-seasons → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """Historical NBA player-seasons from the committed CSV (stdlib-only; empty list
    until the one-time refresh has been run). Same stat keys as every other NBA source."""
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
                source="bref",
                headshot=row["headshot"],
            ))
    return out


def main() -> int:
    argparse.ArgumentParser(description="Refresh the committed 1950–2001 NBA sweep").parse_args()
    refresh()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
