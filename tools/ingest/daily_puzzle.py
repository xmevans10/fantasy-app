"""Mint exactly one guaranteed-novel Keep4 puzzle for today from real stats.

Searches the full curated + generated (single- and pairwise-quirk) theme space across every
distinct player-set window each theme can produce, excludes every signature ever served
(the `puzzle_history` table), and upserts the first unused one as today's `active_date` row.
Meant to run once a night (see .github/workflows/daily-puzzle.yml). The existing `main.py`
ingest job is unaffected — it keeps refreshing the broader stable pool on its own schedule.

Examples:
    python -m tools.ingest.daily_puzzle --dry-run
    python -m tools.ingest.daily_puzzle --upsert
"""
from __future__ import annotations

import argparse
import datetime as dt
import random

from . import assemble, generate
from . import main as ingest_main
from .assemble import PuzzleRow
from .baselines import compute_baselines
from .grade import BaselineTable
from .models import RawSeason
from .themes import KEEP4_THEMES, Theme

# Distinct player-set windows to request per theme when searching for novelty — high enough
# to expose most of a pool_cap=24 theme's ~17 possible clean-boundary windows.
SEARCH_VARIANTS = 20


def _signature(theme_key: str, row: PuzzleRow) -> str:
    ids = sorted(p["id"] for p in row.content["players"])
    return f"{theme_key}|{','.join(ids)}"


def build_candidates(seasons: list[RawSeason],
                     baselines: BaselineTable) -> list[tuple[Theme, PuzzleRow]]:
    """Every (theme, variant-row) pair worth considering. Niche generated themes (single- and
    pairwise-quirk) come first, curated themes last — `pick_novel_puzzle` preserves that order
    so the daily pick favors the more interesting angle whenever an unused one is available."""
    niche = generate.all_niche_candidates(seasons)
    pairs: list[tuple[Theme, PuzzleRow]] = []
    for theme in [*niche, *KEEP4_THEMES]:
        rows = assemble.build_keep4_rows(theme, seasons, baselines, max_variants=SEARCH_VARIANTS)
        pairs += [(theme, row) for row in rows]
    return pairs


def pick_novel_puzzle(
    candidates: list[tuple[Theme, PuzzleRow]], served: set[str], today: dt.date,
) -> tuple[Theme, PuzzleRow, str] | None:
    """Shuffle deterministically per-day (varied day to day, reproducible within a day) while
    keeping niche candidates ranked ahead of curated ones, then return the first row whose
    signature was never served. `None` if the entire space is exhausted."""
    rng = random.Random(today.isoformat())
    order = list(range(len(candidates)))
    rng.shuffle(order)
    rank = {idx: r for r, idx in enumerate(order)}
    is_curated = lambda i: 0 if candidates[i][0].key.startswith("gen") else 1
    ranked = sorted(range(len(candidates)), key=lambda i: (is_curated(i), rank[i]))
    for i in ranked:
        theme, row = candidates[i]
        sig = _signature(theme.key, row)
        if sig not in served:
            return theme, row, sig
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Mint today's guaranteed-novel Keep4 puzzle")
    ap.add_argument("--upsert", action="store_true", help="write the pick to Supabase")
    ap.add_argument("--dry-run", action="store_true", help="build + pick + print, no writes")
    ap.add_argument("--date", type=str, default=None,
                    help="override today's date (YYYY-MM-DD), for testing")
    args = ap.parse_args()
    if not args.upsert and not args.dry_run:
        args.dry_run = True

    ingest_main.load_dotenv()
    today = dt.date.fromisoformat(args.date) if args.date else dt.date.today()

    seasons = ingest_main.gather_seasons(ingest_main.DEFAULT_NFL_YEARS, ingest_main.DEFAULT_GAME_YEARS)
    baselines = BaselineTable(compute_baselines(seasons))

    candidates = build_candidates(seasons, baselines)
    print(f"[daily] {len(candidates)} candidate (theme, variant) pairs built for {today.isoformat()}")

    from .upsert import fetch_history_signatures, upsert, upsert_history
    if args.upsert:
        served = fetch_history_signatures()
        print(f"[daily] {len(served)} signatures already served (puzzle_history)")
    else:
        served = set()
        print("[daily] --dry-run: skipping the puzzle_history lookup (starting from empty history)")

    pick = pick_novel_puzzle(candidates, served, today)
    if pick is None:
        print("[daily] FATAL: entire candidate space already served — no novel puzzle available today")
        return 1
    theme, row, sig = pick

    row.id = f"{row.id}-daily-{today:%Y%m%d}"
    row.content["id"] = row.id
    row.active_date = today.isoformat()

    print(f"\n── today's pick ── {theme.title}  ({row.id})")
    for n, p in enumerate(sorted(row.content["players"], key=lambda p: -p["grade"])):
        pile = "KEEP" if n < 4 else "cut "
        print(f"   {pile} {p['grade']:5.1f}  {p['name']} ({p['teamAbbr']} {p['seasonYear']})")

    if args.upsert:
        sent = upsert([row])
        print(f"\n[daily] upserted {sent} puzzle row")
        hist_sent = upsert_history([{
            "signature": sig, "theme_key": theme.key, "sport": theme.sport,
            "format": "keep4", "puzzle_id": row.id, "served_date": today.isoformat(),
        }])
        print(f"[daily] recorded {hist_sent} history row(s)")
    else:
        print("\n(--dry-run: not written to Supabase)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
