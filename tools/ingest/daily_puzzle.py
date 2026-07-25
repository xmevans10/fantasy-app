"""Mint guaranteed-novel Keep4 puzzles from real stats — one per SPORT per day.

Searches the full curated + generated (single- and pairwise-quirk) theme space across every
distinct player-set window each theme can produce, excludes every signature ever served
(the `puzzle_history` table), and upserts the first unused one per sport as `active_date`'s
row for that sport. Meant to run once a night (see .github/workflows/daily-puzzle.yml). The
existing `main.py` ingest job is unaffected — it keeps refreshing the broader stable pool on
its own schedule.

Originally this minted a single winner per night from a pooled all-sports candidate space —
which meant 4 of 5 sports fell back to the client's non-curated modulo pick every day. Now
every sport gets its own genuinely novel, history-deduped pick each day (the client shows
one pager page per sport, so each page deserves a real daily).

`--count N` mints N consecutive days starting at `--date` (default today) in a single run,
sharing one `gather_seasons()` pull across all of them instead of repeating it per puzzle —
that live pull is ~25-30min and dwarfs everything else this module does, so minting a batch
by invoking this once per day (the naive approach) costs N x that, when the underlying stats
data is identical across a same-session batch. (Per-sport minting shares that same single
pull too — 5 sports/day costs no extra provider time.) Each slot's pick still excludes every
signature served *within this same batch* as it goes (not just history from before the run
started), so a batch can never mint two of its own slots the same puzzle either.

Examples:
    python -m tools.ingest.daily_puzzle --dry-run
    python -m tools.ingest.daily_puzzle --upsert
    python -m tools.ingest.daily_puzzle --upsert --count 30   # backfill the next 30 days
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
from .validate import _VALID_SPORTS

# Stable iteration order for per-sport minting (set iteration order isn't deterministic
# across processes, and logs/tests want a fixed order).
SPORTS: tuple[str, ...] = tuple(sorted(_VALID_SPORTS))

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


def _finalize_row(date: dt.date, theme: Theme, row: PuzzleRow) -> PuzzleRow:
    """Stamp a picked (theme, row) with its date-specific id and active_date."""
    row.id = f"{row.id}-daily-{date:%Y%m%d}"
    row.content["id"] = row.id
    row.active_date = date.isoformat()
    return row


def group_by_sport(
    candidates: list[tuple[Theme, PuzzleRow]],
) -> dict[str, list[tuple[Theme, PuzzleRow]]]:
    """Split the pooled candidate space per sport, preserving order (niche-first ranking in
    `build_candidates` must survive the split — `pick_novel_puzzle` depends on it)."""
    by_sport: dict[str, list[tuple[Theme, PuzzleRow]]] = {}
    for theme, row in candidates:
        by_sport.setdefault(theme.sport, []).append((theme, row))
    return by_sport


def mint_batch(
    candidates_by_sport: dict[str, list[tuple[Theme, PuzzleRow]]], served: set[str],
    targets: list[tuple[dt.date, str]],
) -> list[tuple[dt.date, Theme, PuzzleRow, str]]:
    """Pick a novel puzzle for each (date, sport) slot in order, mutating `served` in place
    as it goes so a later slot in the same batch can never reuse a signature an earlier one
    just picked — not just signatures from before this call. A sport whose candidate space is
    exhausted (or empty) skips just its own slots — it must never block the other sports'
    mints for the same date."""
    minted: list[tuple[dt.date, Theme, PuzzleRow, str]] = []
    for date, sport in targets:
        pick = pick_novel_puzzle(candidates_by_sport.get(sport, []), served, date)
        if pick is None:
            print(f"[daily] {date.isoformat()} {sport}: candidate space exhausted — skipped")
            continue
        theme, row, sig = pick
        served.add(sig)
        minted.append((date, theme, _finalize_row(date, theme, row), sig))
    return minted


def _print_pick(date: dt.date, theme: Theme, row: PuzzleRow) -> None:
    print(f"\n── {date.isoformat()} · {theme.sport} ── {theme.title}  ({row.id})")
    for n, p in enumerate(sorted(row.content["players"], key=lambda p: -p["grade"])):
        pile = "KEEP" if n < 4 else "cut "
        print(f"   {pile} {p['grade']:5.1f}  {p['name']} ({p['teamAbbr']} {p['seasonYear']})")


def main() -> int:
    ap = argparse.ArgumentParser(description="Mint guaranteed-novel Keep4 puzzles (per sport, per day)")
    ap.add_argument("--upsert", action="store_true", help="write the pick(s) to Supabase")
    ap.add_argument("--dry-run", action="store_true", help="build + pick + print, no writes")
    ap.add_argument("--date", type=str, default=None,
                    help="start date override (YYYY-MM-DD), for testing/backfill")
    ap.add_argument("--count", type=int, default=1,
                    help="mint this many consecutive days starting at --date, sharing one "
                         "provider pull instead of repeating it per puzzle")
    args = ap.parse_args()
    if not args.upsert and not args.dry_run:
        args.dry_run = True

    ingest_main.load_dotenv()
    start = dt.date.fromisoformat(args.date) if args.date else dt.date.today()
    target_dates = [start + dt.timedelta(days=i) for i in range(args.count)]
    targets = [(d, sport) for d in target_dates for sport in SPORTS]

    from .upsert import fetch_history_signatures, fetch_served_pairs, upsert, upsert_history
    if args.upsert:
        already = fetch_served_pairs([d.isoformat() for d in target_dates])
        for d, sport in targets:
            if (d.isoformat(), sport) in already:
                print(f"[daily] {d.isoformat()} {sport} already has a puzzle — skipping "
                      "(idempotent; a retried/re-dispatched run shouldn't mint a second one "
                      "and make the client's 'today' pick ambiguous)")
        targets = [(d, s) for d, s in targets if (d.isoformat(), s) not in already]
        if not targets:
            return 0

    seasons = ingest_main.gather_seasons(ingest_main.DEFAULT_NFL_YEARS, ingest_main.DEFAULT_GAME_YEARS)
    baselines = BaselineTable(compute_baselines(seasons))

    candidates_by_sport = group_by_sport(build_candidates(seasons, baselines))
    total = sum(len(v) for v in candidates_by_sport.values())
    per_sport = ", ".join(f"{s}: {len(candidates_by_sport.get(s, []))}" for s in SPORTS)
    print(f"[daily] {total} candidate (theme, variant) pairs built ({per_sport}), "
          f"minting {len(targets)} slot(s) from {targets[0][0].isoformat()}")

    if args.upsert:
        served = fetch_history_signatures()
        print(f"[daily] {len(served)} signatures already served (puzzle_history)")
    else:
        served = set()
        print("[daily] --dry-run: skipping the puzzle_history lookup (starting from empty history)")

    minted = mint_batch(candidates_by_sport, served, targets)
    for date, theme, row, _ in minted:
        _print_pick(date, theme, row)
    if len(minted) < len(targets):
        print(f"[daily] some sports' candidate spaces exhausted — minted {len(minted)}/"
              f"{len(targets)} requested slots")

    if not minted:
        return 1

    if args.upsert:
        sent = upsert([row for _, _, row, _ in minted])
        print(f"\n[daily] upserted {sent} puzzle row(s)")
        hist_sent = upsert_history([{
            "signature": sig, "theme_key": theme.key, "sport": theme.sport,
            "format": "keep4", "puzzle_id": row.id, "served_date": date.isoformat(),
        } for date, theme, row, sig in minted])
        print(f"[daily] recorded {hist_sent} history row(s)")
    else:
        print("\n(--dry-run: not written to Supabase)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
