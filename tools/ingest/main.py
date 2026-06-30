"""BallIQ ingestion CLI — pull real stats, build puzzles, upsert + refresh fallback.

Examples:
    python -m tools.ingest.main --dry-run
    python -m tools.ingest.main --backfill 30 --upsert
    python -m tools.ingest.main --write-fallback

Env (see .env.example): BALLDONTLIE_API_KEY (optional), SUPABASE_URL,
SUPABASE_SERVICE_ROLE_KEY (required for --upsert).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path

from . import assemble
from .assemble import PuzzleRow
from .baselines import compute_baselines
from .grade import grade
from .models import RawSeason
from .providers import espn_nba, nba_balldontlie, nfl_nflverse, seed
from .themes import KEEP4_THEMES
from .validate import validate

ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = Path(__file__).resolve().parent / "data"
FALLBACK_KEEP4 = ROOT / "BallIQ" / "Data" / "keep4_puzzles.json"
FALLBACK_WHOAMI = ROOT / "BallIQ" / "Data" / "whoami_puzzles.json"
FALLBACK_CATALOG = ROOT / "BallIQ" / "Data" / "player_seasons.json"
FALLBACK_BASELINES = ROOT / "BallIQ" / "Data" / "stat_baselines.json"

DEFAULT_NFL_YEARS = list(range(2012, 2024))

# NBA seasons to refresh live (the curated seed defines the target player-seasons).
NBA_LIVE_TARGETS = [(r.name, r.season_year) for r in seed.load_nba()]


def load_dotenv() -> None:
    """Minimal .env loader (no python-dotenv dependency)."""
    env = Path(__file__).resolve().parent / ".env"
    if not env.exists():
        return
    for line in env.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def gather_seasons(nfl_years: list[int]) -> list[RawSeason]:
    seasons: list[RawSeason] = []
    print(f"[nfl] fetching nflverse seasons {nfl_years[0]}–{nfl_years[-1]} …")
    seasons += nfl_nflverse.fetch_years(nfl_years)
    print(f"[nfl] {len(seasons)} player-seasons")

    # ESPN (keyless, historical) is primary; balldontlie (needs a key) then the curated
    # seed are fallbacks so the pipeline always yields real, factual NBA content.
    print("[nba] fetching live season averages from ESPN …")
    nba = espn_nba.fetch_targets(NBA_LIVE_TARGETS)
    if nba:
        print(f"[nba] ESPN: {len(nba)} season averages")
    elif nba_balldontlie.available():
        print("[nba] ESPN empty — trying balldontlie")
        nba = nba_balldontlie.fetch_targets(NBA_LIVE_TARGETS) or seed.load_nba()
    else:
        print("[nba] ESPN empty — using curated real-stat seed (data/nba_seed.csv)")
        nba = seed.load_nba()
    print(f"[nba] {len(nba)} player-seasons")
    return seasons + nba


def build_rows(seasons: list[RawSeason]) -> tuple[list[PuzzleRow], list[PuzzleRow]]:
    keep4: list[PuzzleRow] = []
    for theme in KEEP4_THEMES:
        rows = assemble.build_keep4_rows(theme, seasons)
        print(f"  keep4 {theme.key}: {len(rows)} puzzle(s)")
        keep4 += rows

    entries = assemble.load_whoami_entries(DATA_DIR / "whoami_facts.json")
    whoami = [assemble.build_whoami_row(e) for e in entries]
    print(f"  whoami: {len(whoami)} puzzle(s)")
    return keep4, whoami


def assign_active_dates(rows: list[PuzzleRow], backfill_days: int) -> None:
    """Spread rows across the trailing `backfill_days` so the archive isn't empty.
    The client selects daily by index over the pool; active_date is archival."""
    today = dt.date.today()
    for i, row in enumerate(rows):
        row.active_date = (today - dt.timedelta(days=i % max(1, backfill_days))).isoformat()


def catalog_rows(seasons: list[RawSeason]) -> list[dict]:
    """Deduped player-season rows for the `player_seasons` creation catalog (snake_case)."""
    by_id: dict[str, dict] = {}
    for s in seasons:
        by_id[s.player_id] = {
            "id": s.player_id, "sport": s.sport, "name": s.name,
            "team_abbr": s.team_abbr, "season_year": s.season_year,
            "position": s.position, "stats": s.stats,
        }
    return list(by_id.values())


def write_catalog_fallback(seasons: list[RawSeason], per_theme: int = 40) -> None:
    """Trimmed bundled catalog so the Keep4 create flow works before the table is populated:
    the top `per_theme` graded seasons of each theme (union), in the camelCase-keyed shape
    the Swift `CatalogSeason` decodes (team_abbr/season_year stay snake_case)."""
    keep_ids: set[str] = set()
    for theme in KEEP4_THEMES:
        pool = [s for s in seasons
                if s.sport == theme.sport and s.position in theme.positions
                and not any(s.stats.get(k, 0.0) < v for k, v in theme.min_stats.items())]
        pool.sort(key=lambda s: grade(s.stats, theme.scale), reverse=True)
        keep_ids.update(s.player_id for s in pool[:per_theme])
    rows = [r for r in catalog_rows(seasons) if r["id"] in keep_ids]
    FALLBACK_CATALOG.write_text(
        json.dumps(rows, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"[catalog] wrote {len(rows)} player-seasons → BallIQ/Data/player_seasons.json")


def write_baselines_fallback(seasons: list[RawSeason]) -> None:
    """Era-adjusted scoring baselines (per sport/stat/year) from the full raw pull."""
    rows = compute_baselines(seasons)
    FALLBACK_BASELINES.write_text(
        json.dumps(rows, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"[baselines] wrote {len(rows)} stat baselines → BallIQ/Data/stat_baselines.json")


def write_fallback(keep4: list[PuzzleRow], whoami: list[PuzzleRow]) -> None:
    """Regenerate the bundled offline JSON from real data (one keep4 per theme)."""
    seen_theme: set[str] = set()
    keep4_subset = []
    for row in keep4:
        theme_key = row.id.rsplit("-", 1)[0]
        if theme_key not in seen_theme:
            seen_theme.add(theme_key)
            keep4_subset.append(row.content)
    FALLBACK_KEEP4.write_text(
        json.dumps(keep4_subset, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    FALLBACK_WHOAMI.write_text(
        json.dumps([r.content for r in whoami], indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[fallback] wrote {len(keep4_subset)} keep4 + {len(whoami)} whoami → BallIQ/Data/")


def print_summary(keep4: list[PuzzleRow], whoami: list[PuzzleRow]) -> None:
    sample = keep4[0]
    print("\n── sample keep4 ──", sample.id, f"({sample.content['theme']})")
    ranked = sorted(sample.content["players"], key=lambda p: -p["grade"])
    for n, p in enumerate(ranked):
        pile = "KEEP" if n < 4 else "cut "
        cols = " ".join(f"{s['label']} {s['value']}" for s in p["stats"])
        print(f"   {pile} {p['grade']:5.1f}  {p['name']} ({p['teamAbbr']} {p['seasonYear']})  {cols}")
    if whoami:
        w = whoami[0]
        print("\n── sample whoami ──", w.content["answer"]["canonical"])
        for cl in w.content["clues"]:
            print(f"   {cl['order']}. [{cl['kind']}] {cl['text']}")


def main() -> int:
    ap = argparse.ArgumentParser(description="BallIQ real-sports-data ingestion")
    ap.add_argument("--backfill", type=int, default=30, help="archive span in days for active_date")
    ap.add_argument("--nfl-years", type=int, nargs="+", default=DEFAULT_NFL_YEARS)
    ap.add_argument("--upsert", action="store_true", help="upsert rows into Supabase")
    ap.add_argument("--catalog", action="store_true",
                    help="also upsert player_seasons (creation catalog) + write its fallback")
    ap.add_argument("--write-fallback", action="store_true", help="rewrite bundled offline JSON")
    ap.add_argument("--dry-run", action="store_true", help="build + validate + print, no writes")
    args = ap.parse_args()

    load_dotenv()
    seasons = gather_seasons(args.nfl_years)
    keep4, whoami = build_rows(seasons)
    all_rows = keep4 + whoami

    for row in all_rows:
        validate(row)
    print(f"[validate] {len(all_rows)} rows OK")

    assign_active_dates(all_rows, args.backfill)
    print_summary(keep4, whoami)

    if args.write_fallback:
        write_fallback(keep4, whoami)
        write_catalog_fallback(seasons)
        write_baselines_fallback(seasons)

    if args.upsert:
        from .upsert import upsert, upsert_catalog
        sent = upsert(all_rows)
        print(f"[upsert] sent {sent} puzzle rows to Supabase")
        if args.catalog:
            rows = catalog_rows(seasons)
            print(f"[upsert] sending {len(rows)} player_seasons …")
            print(f"[upsert] sent {upsert_catalog(rows)} catalog rows")
    elif args.catalog and not args.dry_run:
        # --catalog without --upsert just refreshes the bundled fallbacks.
        write_catalog_fallback(seasons)
        write_baselines_fallback(seasons)
    elif not args.dry_run and not args.write_fallback:
        print("\n(no action: pass --upsert and/or --write-fallback, or --dry-run)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
