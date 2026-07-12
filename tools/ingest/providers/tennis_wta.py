"""WTA full-history season stats — Jeff Sackmann's `tennis_wta` dataset via the
`chestnutforty/tennis_wta` GitHub fork (the canonical `JeffSackmann/tennis_wta` upstream
is deleted, like its ATP sibling; this fork preserves the standard schema and — unlike
the older `ppaulojr/tennis_wta` snapshot that dies mid-2015 — carries complete main-tour
match files through the 2025 season, verified against real results: 2025 slam champions
Keys/Gauff/Swiatek/Sabalenka all check out).

The women's-tour counterpart of `tennis_atp.py`: every tour-level match (the
`wta_matches_YYYY.csv` files only — the `qual_itf` files are qualifying/ITF noise and
are ignored) aggregated into (player, season) lines: matches won/lost, titles, Grand
Slam titles. Schema is byte-for-byte the Sackmann ATP shape (winner_name/winner_ioc/
loser_name/loser_ioc/round/tourney_level, slams = level 'G'), so the aggregation is
imported from `tennis_atp` rather than re-implemented.

Coverage is 1968–2025: the fork also has a `wta_matches_2026.csv`, but it's a partial
in-progress year (frozen at the fork's last push) and shipping half-seasons as if they
were full ones would poison the stat lines, so it's excluded. The fork is a frozen
snapshot — no cron; re-run the refresh manually if a fresher mirror appears.

Headshots: identical M16 contract to the ATP sweep — one Wikipedia summary lookup per
player (shared `wikimedia.headshot`, tennis context), and players without a confident
tennis-context photo are dropped entirely, never shipped photo-less.

Same split as tennis_atp: a network-heavy refresh path writing a committed CSV
(`data/tennis_wta_seasons.csv`) and a stdlib runtime loader.

Run:  python -m tools.ingest.providers.tennis_wta  [--from 1968 --to 2025]
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

from ..models import RawSeason
from .http import fetch_text
from .tennis_atp import CSV_FIELDS, MIN_MATCHES, _aggregate_year
from .wikimedia import headshot as wiki_headshot

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "tennis_wta_seasons.csv"

_MATCHES_URL = "https://raw.githubusercontent.com/chestnutforty/tennis_wta/master/wta_matches_{year}.csv"

MIN_YEAR = 1968
MAX_YEAR = 2025   # 2026 exists in the fork but is a partial in-progress year — excluded


def _wiki_headshot(name: str) -> str:
    """Tennis-context Wikipedia thumbnail (shared mechanism: see `providers/wikimedia.py`)."""
    return wiki_headshot(name, context="tennis")


def refresh(year_from: int, year_to: int) -> None:
    """Download + aggregate every season in range, resolve headshots, write the CSV."""
    rows: list[dict] = []
    players: set[str] = set()
    for year in range(year_from, year_to + 1):
        try:
            text = fetch_text(_MATCHES_URL.format(year=year),
                              cache_key=f"tennis_wta_matches_{year}.csv", ttl_hours=24 * 90)
        except Exception as err:  # noqa: BLE001 — a missing year shouldn't sink the sweep
            print(f"[tennis-wta] {year}: skipped ({err})")
            continue
        seasons = _aggregate_year(year, text)
        kept = 0
        for (name, country), stats in seasons.items():
            if stats["matches_won"] + stats["matches_lost"] < MIN_MATCHES:
                continue
            rows.append({"name": name, "country": country, "season_year": year,
                         "matches_won": int(stats["matches_won"]),
                         "matches_lost": int(stats["matches_lost"]),
                         "titles": int(stats["titles"]),
                         "grand_slams": int(stats["grand_slams"]),
                         "headshot": ""})
            players.add(name)
            kept += 1
        print(f"[tennis-wta] {year}: {kept} qualifying player-seasons")

    print(f"[tennis-wta] resolving Wikipedia headshots for {len(players)} players …")
    headshots = {name: _wiki_headshot(name) for name in sorted(players)}
    matched = sum(1 for v in headshots.values() if v)
    print(f"[tennis-wta] {matched}/{len(players)} players matched a real tennis photo")

    # M16 contract: no photo, no row — dropped, not shipped photo-less.
    final = []
    for row in rows:
        if shot := headshots.get(row["name"], ""):
            row["headshot"] = shot
            final.append(row)

    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(final)
    print(f"[tennis-wta] wrote {len(final)} player-seasons → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """Historical WTA player-seasons from the committed CSV (stdlib-only; empty list
    until the one-time refresh has been run). Same stat keys and `team_abbr`=country
    convention as `tennis_atp.load_seasons`, so both tours merge cleanly downstream."""
    if not CSV_PATH.exists():
        return []
    out: list[RawSeason] = []
    with CSV_PATH.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out.append(RawSeason(
                name=row["name"],
                team_abbr=row["country"],
                season_year=int(row["season_year"]),
                sport="tennis",
                position="Player",
                stats={
                    "matches_won": float(row["matches_won"]),
                    "matches_lost": float(row["matches_lost"]),
                    "titles": float(row["titles"]),
                    "grand_slams": float(row["grand_slams"]),
                },
                source="tennis_wta",
                headshot=row["headshot"],
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed WTA season sweep (1968–2025)")
    ap.add_argument("--from", dest="year_from", type=int, default=MIN_YEAR)
    ap.add_argument("--to", dest="year_to", type=int, default=MAX_YEAR)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
