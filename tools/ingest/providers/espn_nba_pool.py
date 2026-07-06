"""NBA pool discovery — enumerate a broad set of *star* NBA athlete ids via pyespn's
season stat-leaders, so the Keep4 themes draw from hundreds of real player-seasons
instead of the 34-row hand seed.

This is the ONLY module that imports `pyespn` (a heavyweight, network-bound dep). It
is run *occasionally* to refresh `data/nba_player_ids.json` — NOT on every pipeline
run. The daily pipeline reads that committed id map and pulls full season lines through
the keyless ESPN stats endpoint (`espn_nba.fetch_by_ids`), keeping the runtime path
stdlib-only and the data real/factual.

Run:  python -m tools.ingest.providers.espn_nba_pool  [--from 2003 --to 2025]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
POOL_PATH = DATA_DIR / "nba_player_ids.json"

# Stat-leader seasons to sweep. ESPN's per-game leaders exist 2003-04 → present; each
# season returns ~16 categories × ~25 players, which dedupes to the era's real stars.
# DEFAULT_TO is today's year, not a literal — see mlb_pool.py's identical rationale: a
# fixed year quietly stops covering new seasons the moment that year ends, and `discover`
# already tolerates a season with no leaders yet (logs "skipped", keeps going).
DEFAULT_FROM = 2003
DEFAULT_TO = dt.date.today().year


def discover(year_from: int = DEFAULT_FROM, year_to: int = DEFAULT_TO) -> dict[str, str]:
    """Return `{espn_athlete_id: display_name}` for every player who led *any* per-game
    category in *any* season in range. Imported lazily so `pyespn` isn't a hard dep."""
    from pyespn import PYESPN  # noqa: PLC0415 — heavy/optional, only needed here

    nba = PYESPN("nba")
    players: dict[str, str] = {}
    for year in range(year_from, year_to + 1):
        try:
            nba.load_season_league_stat_leaders(season=year)
            for cat in nba.league.league_leaders.get(year, []):
                for leader in cat.athletes.get(year, []):
                    a = leader.athlete
                    if a and a.id:
                        players.setdefault(str(a.id), a.display_name)
            print(f"[pool] {year}: {len(players)} unique players so far")
        except Exception as err:  # noqa: BLE001
            print(f"[pool] {year}: skipped ({err})")
    return players


def write_pool(players: dict[str, str]) -> None:
    POOL_PATH.write_text(json.dumps(players, indent=2, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    print(f"[pool] wrote {len(players)} athlete ids → {POOL_PATH}")


def load_pool() -> dict[str, str]:
    """`{athlete_id: name}` from the committed map; empty dict if it hasn't been built."""
    if not POOL_PATH.exists():
        return {}
    return json.loads(POOL_PATH.read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the NBA athlete-id pool via pyespn")
    ap.add_argument("--from", dest="year_from", type=int, default=DEFAULT_FROM)
    ap.add_argument("--to", dest="year_to", type=int, default=DEFAULT_TO)
    args = ap.parse_args()
    write_pool(discover(args.year_from, args.year_to))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
