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

from . import assemble, curation, generate
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

# How long a theme *title* stays on the bench after a sport serves it. Signature-novelty
# already guarantees the eight cards are never repeated, but a theme has many signatures, and
# the title is what the player reads (and what the daily-drop push announces). Three weeks is
# comfortably inside every sport's post-expansion viable space, and the cooldown is a soft
# ranking penalty (see `pick_novel_puzzle`) so it can never block a mint if it isn't.
THEME_COOLDOWN_DAYS = 21


def _signature(theme_key: str, row: PuzzleRow) -> str:
    ids = sorted(p["id"] for p in row.content["players"])
    return f"{theme_key}|{','.join(ids)}"


# How many viable themes to ROLL per sport per batch, and the ceiling on rolls spent finding
# them. Enough that a day's pick has real choice and the theme cooldown can be satisfied,
# without re-enumerating a space we only take five puzzles from.
ROLL_THEMES = 60
ROLL_ATTEMPTS = 500


def build_candidates(seasons: list[RawSeason], baselines: BaselineTable,
                     rng: random.Random | None = None) -> list[tuple[Theme, PuzzleRow]]:
    """Every (theme, variant-row) pair worth considering. Rolled niche themes come first,
    curated themes last — `pick_novel_puzzle` preserves that order so the daily pick favors the
    more interesting angle whenever an unused one is available.

    Themes are ROLLED, not enumerated. Enumerating every (position x slice x quirk) combination
    cost 14,888 viability builds and 20.9 minutes on the live catalog to choose five puzzles,
    and could only ever reach the combinations the grid was written to produce. Rolling composes
    a spec at random from the axes — era, franchise, league/nationality, one or two quirks — so
    the reachable space is their full product (including era x club x two quirks, which the grid
    never enumerated because crossing everything with everything is what made it unaffordable),
    at a cost of tens of builds instead of thousands.

    The curated themes stay in the pool unrolled: they are editorial, they are the fallback when
    a thin sport's rolls all miss, and `pick_novel_puzzle` already ranks them last."""
    rng = rng or random.Random(0)
    pairs: list[tuple[Theme, PuzzleRow]] = []
    themes: list[Theme] = []
    for cohort, cfg in curation.SPORTS.items():
        if not any(s.sport == cfg.sport for s in seasons):
            continue          # nothing pulled for this sport this run
        themes += generate.roll_viable_themes(cfg, seasons, rng, ROLL_THEMES, ROLL_ATTEMPTS,
                                              label=cohort)
    for theme in [*themes, *KEEP4_THEMES]:
        rows = assemble.build_keep4_rows(theme, seasons, baselines, max_variants=SEARCH_VARIANTS)
        pairs += [(theme, row) for row in rows]
    return pairs


def pick_novel_puzzle(
    candidates: list[tuple[Theme, PuzzleRow]], served: set[str], today: dt.date,
    recent_themes: set[str] | frozenset[str] = frozenset(),
) -> tuple[Theme, PuzzleRow, str] | None:
    """Shuffle deterministically per-day (varied day to day, reproducible within a day) while
    keeping niche candidates ranked ahead of curated ones, then return the first row whose
    signature was never served. `None` if the entire space is exhausted.

    `recent_themes` are theme *keys* this sport has served inside the cooldown window
    (`THEME_COOLDOWN_DAYS`). They're sorted to the back rather than filtered out, so the
    cooldown shapes the pick without ever being able to starve a slot: a sport whose whole
    space is inside the window still mints, it just mints last-resort. That soft form matters
    because signature-novelty is the hard guarantee here and must stay the binding one."""
    rng = random.Random(today.isoformat())
    order = list(range(len(candidates)))
    rng.shuffle(order)
    rank = {idx: r for r, idx in enumerate(order)}
    is_curated = lambda i: 0 if candidates[i][0].key.startswith("gen") else 1
    is_recent = lambda i: 1 if candidates[i][0].key in recent_themes else 0
    ranked = sorted(range(len(candidates)),
                    key=lambda i: (is_recent(i), is_curated(i), rank[i]))
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
    recent_themes: dict[str, set[str]] | None = None,
) -> list[tuple[dt.date, Theme, PuzzleRow, str]]:
    """Pick a novel puzzle for each (date, sport) slot in order, mutating `served` in place
    as it goes so a later slot in the same batch can never reuse a signature an earlier one
    just picked — not just signatures from before this call. A sport whose candidate space is
    exhausted (or empty) skips just its own slots — it must never block the other sports'
    mints for the same date.

    `recent_themes` (per sport, from `puzzle_history` inside the cooldown window) is likewise
    mutated as the batch runs, so minting 30 days in one invocation spreads themes across the
    whole batch instead of only avoiding what was already in the table when it started."""
    recent = {s: set(k) for s, k in (recent_themes or {}).items()}
    minted: list[tuple[dt.date, Theme, PuzzleRow, str]] = []
    for date, sport in targets:
        pick = pick_novel_puzzle(candidates_by_sport.get(sport, []), served, date,
                                 recent.get(sport, frozenset()))
        if pick is None:
            print(f"[daily] {date.isoformat()} {sport}: candidate space exhausted — skipped")
            continue
        theme, row, sig = pick
        served.add(sig)
        recent.setdefault(sport, set()).add(theme.key)
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

    from .upsert import (fetch_history_signatures, fetch_recent_theme_keys, fetch_served_pairs,
                         upsert, upsert_history)
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

    # Seeded on the batch's first date, so a re-dispatched run for the same day rolls the same
    # themes and the mint stays reproducible.
    candidates_by_sport = group_by_sport(
        build_candidates(seasons, baselines, random.Random(f"roll-{start.isoformat()}")))
    total = sum(len(v) for v in candidates_by_sport.values())
    per_sport = ", ".join(f"{s}: {len(candidates_by_sport.get(s, []))}" for s in SPORTS)
    print(f"[daily] {total} candidate (theme, variant) pairs built ({per_sport}), "
          f"minting {len(targets)} slot(s) from {targets[0][0].isoformat()}")

    if args.upsert:
        served = fetch_history_signatures()
        cooldown_since = (start - dt.timedelta(days=THEME_COOLDOWN_DAYS)).isoformat()
        recent_themes = fetch_recent_theme_keys(cooldown_since)
        print(f"[daily] {len(served)} signatures already served (puzzle_history); "
              f"{sum(len(v) for v in recent_themes.values())} theme(s) on cooldown since "
              f"{cooldown_since}")
    else:
        served = set()
        recent_themes = {}
        print("[daily] --dry-run: skipping the puzzle_history lookup (starting from empty history)")

    minted = mint_batch(candidates_by_sport, served, targets, recent_themes)
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
