"""MLB pool discovery — enumerate a broad set of *notable* MLB person ids from the
keyless MLB Stats API stat-leaders, so the baseball Keep4 themes draw from hundreds of
real player-seasons instead of the 23-id hand list in `main.py`.

Mirrors `espn_nba_pool.py`'s two-phase design: this module is run *occasionally* to
refresh `data/mlb_player_ids.json`, and the daily pipeline reads that committed id map
and pulls full careers through the keyless stats endpoint (`mlb_stats.fetch_by_ids`).
Unlike the NBA pool this needs no heavyweight dep — the leaders endpoint is plain JSON —
but it's still kept out of the per-run path so the pipeline's fetch time stays bounded.

Sweeping season stat-leaders (not the ~1400-player season roster) keeps the pool to the
era's genuinely notable hitters and pitchers, the players a fan would recognize on a
Keep4 card.

Run:  python -m tools.ingest.providers.mlb_pool  [--from 1975 --to 2024]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path

from .http import fetch_json

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
POOL_PATH = DATA_DIR / "mlb_player_ids.json"

_LEADERS = ("https://statsapi.mlb.com/api/v1/stats/leaders"
            "?leaderCategories={cat}&season={year}&sportId=1&limit=50")

# Hitting + pitching categories swept per season. Each returns the season's top ~50 in
# that category; the union across categories/years dedupes to the real stars of each era.
HITTING_CATS = [
    "homeRuns", "battingAverage", "onBasePlusSlugging", "runsBattedIn", "hits",
    "stolenBases", "runs", "doubles", "triples", "walks", "totalBases",
    "sluggingPercentage", "onBasePercentage",
]
PITCHING_CATS = [
    "wins", "earnedRunAverage", "strikeouts", "saves", "whip", "inningsPitched",
]

# Live leaders exist deep into MLB history; default sweep covers everything from the
# late Mays/Aaron/Koufax era on while staying a manageable request count (~19 cats ×
# span, mostly cached). Extended 1975 → 1955 in M18 (2026-07-09) to fill Draft & Spin's
# thin pre-1976 team-years — the default matters because discover() rebuilds the pool
# from scratch: if the weekly discover-players.yml swept a narrower range than the last
# manual run, players whose careers ended before its start year would silently fall
# back OUT of the pool. DEFAULT_TO is today's year, not a literal — a fixed year
# quietly stops covering new seasons the moment that year ends. `discover` skips any
# (category, year) that errors (see below), so sweeping the current season before it
# has standings is a harmless no-op.
DEFAULT_FROM = 1955
DEFAULT_TO = dt.date.today().year

# A player must rank in the top ~50 of at least this many (category, season) pairs to
# make the pool. Filters pure one-offs (e.g. top-50 in triples for a single fluke year)
# while keeping anyone with a sustained peak, so the Create-search catalog stays stars,
# not September call-ups.
MIN_APPEARANCES = 3


def discover(year_from: int = DEFAULT_FROM, year_to: int = DEFAULT_TO,
             min_appearances: int = MIN_APPEARANCES) -> dict[str, str]:
    """Return `{person_id: full_name}` for every player who ranked in the top ~50 of a
    swept category in at least `min_appearances` (category, season) pairs in range.
    Best-effort per (category, year): a failed pull is skipped so one bad season never
    aborts the sweep."""
    counts: dict[str, int] = {}
    names: dict[str, str] = {}
    cats = HITTING_CATS + PITCHING_CATS
    for year in range(year_from, year_to + 1):
        before = len(counts)
        for cat in cats:
            try:
                data = fetch_json(_LEADERS.format(cat=cat, year=year),
                                  cache_key=f"mlb_leaders_{cat}_{year}.json")
            except Exception as err:  # noqa: BLE001
                print(f"[mlb-pool] {year} {cat}: skipped ({err})")
                continue
            for group in data.get("leagueLeaders", []):
                for leader in group.get("leaders", []):
                    person = leader.get("person") or {}
                    pid, name = person.get("id"), person.get("fullName")
                    if pid and name:
                        pid = str(pid)
                        counts[pid] = counts.get(pid, 0) + 1
                        names[pid] = name
        print(f"[mlb-pool] {year}: {len(counts) - before} new ids seen (total seen {len(counts)})")
    players = {pid: names[pid] for pid, c in counts.items() if c >= min_appearances}
    print(f"[mlb-pool] {len(players)} players with >= {min_appearances} category-seasons "
          f"(of {len(counts)} seen)")
    return players


def write_pool(players: dict[str, str]) -> None:
    POOL_PATH.write_text(json.dumps(players, indent=2, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    print(f"[mlb-pool] wrote {len(players)} person ids → {POOL_PATH}")


def load_pool() -> dict[str, str]:
    """`{person_id: name}` from the committed map; empty dict if it hasn't been built."""
    if not POOL_PATH.exists():
        return {}
    return json.loads(POOL_PATH.read_text(encoding="utf-8"))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Refresh the MLB person-id pool")
    ap.add_argument("--from", dest="year_from", type=int, default=DEFAULT_FROM)
    ap.add_argument("--to", dest="year_to", type=int, default=DEFAULT_TO)
    args = ap.parse_args()
    write_pool(discover(args.year_from, args.year_to))
