"""Tennis full-history season stats — Jeff Sackmann's `tennis_atp` dataset via the
`stakah/tennis_atp` GitHub snapshot (the canonical upstream repo is deleted; this fork
preserves the standard schema, tour-level matches 1968–2018).

Ends M18's "tennis is 20 hand-curated rows" era: aggregating every tour-level match into
(player, season) lines — matches won/lost, titles, Grand Slam titles — yields thousands
of real player-seasons across five decades. The snapshot is **frozen at 2018** by nature
(no maintained mirror of the upstream exists — re-verified 3 times, see seed.py), so:
- 1968–2018 comes from this provider,
- 2019+ marquee seasons keep coming from the hand-curated seed (`data/tennis_seed.csv`),
  which also wins any (player, year) collision (its rows carry individually verified
  stats + headshots).
No cron needed: a frozen dataset means the committed CSV never drifts.

Headshots (the M16 contract: every bundled player has a real photo): the refresh
resolves each qualifying player once against Wikipedia's REST summary API — same
approach the seed CSVs used — keeping a player only if their page's description
actually says *tennis* (guards against a same-named non-player's photo) and carries a
thumbnail. Players without a confident photo are dropped entirely rather than shipped
photo-less, so the bundled-puzzle headshot guard (`test_headshot_coverage.py`) holds by
construction.

Same split as hoopr_nba: a network-heavy refresh path writing a committed CSV
(`data/tennis_atp_seasons.csv`) and a stdlib runtime loader.

Run:  python -m tools.ingest.providers.tennis_atp  [--from 1968 --to 2018]
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
CSV_PATH = DATA_DIR / "tennis_atp_seasons.csv"

_MATCHES_URL = "https://raw.githubusercontent.com/stakah/tennis_atp/master/atp_matches_{year}.csv"

MIN_YEAR = 1968
MAX_YEAR = 2018   # the snapshot's hard end — later seasons live in the curated seed

# A real tour season, not a one-tournament qualifier cameo. 15 tour-level matches ≈ a
# player who was genuinely on tour that year.
MIN_MATCHES = 15

CSV_FIELDS = ["name", "country", "season_year", "matches_won", "matches_lost",
              "titles", "grand_slams", "headshot"]


def _aggregate_year(year: int, text: str) -> dict[tuple[str, str], dict[str, float]]:
    """(player, country) → season stat dict for one year's match file."""
    out: dict[tuple[str, str], dict[str, float]] = collections.defaultdict(
        lambda: {"matches_won": 0.0, "matches_lost": 0.0, "titles": 0.0, "grand_slams": 0.0})
    for row in csv.DictReader(io.StringIO(text)):
        winner = (row.get("winner_name") or "").strip()
        loser = (row.get("loser_name") or "").strip()
        if winner:
            key = (winner, (row.get("winner_ioc") or "").strip())
            out[key]["matches_won"] += 1
            if (row.get("round") or "") == "F":
                out[key]["titles"] += 1
                if (row.get("tourney_level") or "") == "G":
                    out[key]["grand_slams"] += 1
        if loser:
            out[(loser, (row.get("loser_ioc") or "").strip())]["matches_lost"] += 1
    return out


def _wiki_headshot(name: str) -> str:
    """Tennis-context Wikipedia thumbnail (shared mechanism: see `providers/wikimedia.py`)."""
    return wiki_headshot(name, context="tennis")


def refresh(year_from: int, year_to: int) -> None:
    """Download + aggregate every season in range, resolve headshots, write the CSV."""
    # (name, country, year) → stats, only for real tour seasons.
    rows: list[dict] = []
    players: set[str] = set()
    for year in range(year_from, year_to + 1):
        try:
            text = fetch_text(_MATCHES_URL.format(year=year),
                              cache_key=f"tennis_atp_matches_{year}.csv", ttl_hours=24 * 90)
        except Exception as err:  # noqa: BLE001 — a missing year shouldn't sink the sweep
            print(f"[tennis-atp] {year}: skipped ({err})")
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
        print(f"[tennis-atp] {year}: {kept} qualifying player-seasons")

    print(f"[tennis-atp] resolving Wikipedia headshots for {len(players)} players …")
    headshots = {name: _wiki_headshot(name) for name in sorted(players)}
    matched = sum(1 for v in headshots.values() if v)
    print(f"[tennis-atp] {matched}/{len(players)} players matched a real tennis photo")

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
    print(f"[tennis-atp] wrote {len(final)} player-seasons → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """Historical tennis player-seasons from the committed CSV (stdlib-only; empty list
    until the one-time refresh has been run). Same stat keys and `team_abbr`=country
    convention as `seed.load_tennis`, so both sources merge cleanly downstream."""
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
                source="tennis_atp",
                headshot=row["headshot"],
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed ATP season sweep (1968–2018)")
    ap.add_argument("--from", dest="year_from", type=int, default=MIN_YEAR)
    ap.add_argument("--to", dest="year_to", type=int, default=MAX_YEAR)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
