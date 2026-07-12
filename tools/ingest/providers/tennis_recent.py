"""Post-snapshot ATP season stats (2019–2025) — Jeff Sackmann's `tennis_atp` dataset via
the `racketbracket/tennis_atp` GitHub fork.

`tennis_atp.py` is pinned to the `stakah/tennis_atp` snapshot, which is frozen at 2018;
when it shipped, no maintained mirror of the deleted upstream was known. One has since
been verified: the `racketbracket/tennis_atp` fork carries the standard Sackmann schema
with main-tour match files through 2026, and its recent years check out against real
results (2025 slam champions Sinner ×2 / Alcaraz ×2; 2020 is short because COVID
cancelled Wimbledon — correctly so). This provider fills exactly the gap the frozen
snapshot left: **2019–2025**. It deliberately does NOT re-cover 1968–2018 (that stays
`tennis_atp.py`'s committed CSV — no reason to churn 3,900 verified rows), and it
excludes the fork's partial in-progress `atp_matches_2026.csv` (half-seasons shipped as
full ones would poison the stat lines).

Two overlap notes for whoever wires this into main.py:
- The hand-curated seed (`data/tennis_seed.csv`) carries a few 2019+ marquee ATP
  seasons with individually verified stats; per the existing tennis convention the seed
  should win any (player, year) collision.
- The fork is a frozen snapshot (last verified push 2026-06); no cron — re-run the
  refresh manually when it advances.

Aggregation, thresholds, headshot gate, and CSV shape are all identical to
`tennis_atp.py` (the aggregation is imported from it, not re-implemented): tour-level
matches → (player, season) matches won/lost, titles, Grand Slam titles; MIN_MATCHES
filter; one Wikipedia summary lookup per player with the tennis-context photo gate —
no confident photo, no row.

Run:  python -m tools.ingest.providers.tennis_recent  [--from 2019 --to 2025]
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
CSV_PATH = DATA_DIR / "tennis_recent_seasons.csv"

_MATCHES_URL = "https://raw.githubusercontent.com/racketbracket/tennis_atp/master/atp_matches_{year}.csv"

MIN_YEAR = 2019   # tennis_atp.py's snapshot ends at 2018 — this provider starts where it stops
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
                              cache_key=f"tennis_recent_matches_{year}.csv", ttl_hours=24 * 90)
        except Exception as err:  # noqa: BLE001 — a missing year shouldn't sink the sweep
            print(f"[tennis-recent] {year}: skipped ({err})")
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
        print(f"[tennis-recent] {year}: {kept} qualifying player-seasons")

    print(f"[tennis-recent] resolving Wikipedia headshots for {len(players)} players …")
    headshots = {name: _wiki_headshot(name) for name in sorted(players)}
    matched = sum(1 for v in headshots.values() if v)
    print(f"[tennis-recent] {matched}/{len(players)} players matched a real tennis photo")

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
    print(f"[tennis-recent] wrote {len(final)} player-seasons → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """Post-2018 ATP player-seasons from the committed CSV (stdlib-only; empty list
    until the one-time refresh has been run). Same stat keys and `team_abbr`=country
    convention as `tennis_atp.load_seasons`, so all tennis sources merge cleanly
    downstream."""
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
                source="tennis_recent",
                headshot=row["headshot"],
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed post-snapshot ATP sweep (2019–2025)")
    ap.add_argument("--from", dest="year_from", type=int, default=MIN_YEAR)
    ap.add_argument("--to", dest="year_to", type=int, default=MAX_YEAR)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
