"""Mint the canonical Who Am I? pick for each sport per day — least-recently-served.

The Keep4 daily (daily_puzzle.py) can promise exact novelty because its candidate space is
huge (every theme x player-set window). Who Am I?'s pool is a small hand-authored set
(data/whoami_facts.json), so a "never repeat" guarantee would exhaust in weeks and then
hard-fail. Instead the picker prefers the entry served longest ago for that sport (never-served
entries first), tie-broken by a per-day deterministic shuffle — honest rotation with a real
audit trail (`whoami_history`), replacing the client's old blind day-of-year modulo that
repeated on a fixed calendar cycle with no history at all.

Same idempotent-upsert shape as daily_puzzle.py: a (date, sport) slot that already has a
`whoami_history` row is skipped, so a retried run can't mint a second competing pick. No
provider pull needed — the pool is a committed JSON file, so this runs in seconds.

Examples:
    python -m tools.ingest.daily_whoami --dry-run
    python -m tools.ingest.daily_whoami --upsert
    python -m tools.ingest.daily_whoami --upsert --count 30
"""
from __future__ import annotations

import argparse
import datetime as dt
import random
from collections import Counter

from . import assemble, whoami_clues, whoami_pool
from . import main as ingest_main
from .assemble import PuzzleRow
from .daily_puzzle import SPORTS
from .models import WhoAmIEntry, slug
from .validate import validate


def player_key(entry: WhoAmIEntry) -> str:
    """Stable identity for history bookkeeping — the slug of the canonical answer name."""
    return slug(entry.canonical)


# How often each difficulty tier gets the daily slot, per sport. A hard puzzle roughly every
# fifth day: enough that the tier is a real part of the game (and its point multiplier is
# worth chasing) without making the daily feel like a wall most mornings. The draw is
# deterministic per (date, sport), so every player in a sport sees the same tier on a day.
TIER_WEIGHTS: dict[str, float] = {"easy": 0.4, "medium": 0.4, "hard": 0.2}


def pick_tier(today: dt.date, sport: str) -> str:
    """The difficulty tier to serve `sport` on `today`, drawn from `TIER_WEIGHTS`."""
    rng = random.Random(f"whoami-tier-{sport}-{today.isoformat()}")
    tiers = list(TIER_WEIGHTS)
    return rng.choices(tiers, weights=[TIER_WEIGHTS[t] for t in tiers], k=1)[0]


def pick_lrs_entry(
    entries: list[WhoAmIEntry], last_served: dict[tuple[str, str], str],
    today: dt.date, sport: str, tier: str | None = None,
) -> WhoAmIEntry | None:
    """The least-recently-served entry for `sport` (never-served first), tie-broken by a
    per-(day, sport)-seeded shuffle so same-recency entries rotate in a varied but
    reproducible order. `last_served` maps (sport, player_key) -> most recent served_date
    (ISO string, so lexicographic order IS chronological; "" sorts before every real date).

    `tier` restricts the draw to one difficulty (see `pick_tier`). A tier with no entries for
    this sport falls back to the sport's full pool rather than returning nothing — that's a
    real state for a thin sport, and a served puzzle of the wrong difficulty beats no daily.
    """
    pool = [e for e in entries if e.sport == sport]
    if tier:
        in_tier = [e for e in pool if whoami_clues.difficulty_of(e) == tier]
        if in_tier:
            pool = in_tier
        else:
            print(f"[whoami] {today.isoformat()} {sport}: no {tier} entries — "
                  "drawing from the full pool for this sport")
    if not pool:
        return None
    rng = random.Random(f"whoami-{sport}-{today.isoformat()}")
    order = list(range(len(pool)))
    rng.shuffle(order)
    rank = {idx: r for r, idx in enumerate(order)}
    ranked = sorted(range(len(pool)),
                    key=lambda i: (last_served.get((sport, player_key(pool[i])), ""), rank[i]))
    return pool[ranked[0]]


def _finalize_row(date: dt.date, entry: WhoAmIEntry) -> PuzzleRow:
    """The dated daily row for `entry` — a separate row from main.py's undated archival copy
    of the same player (same id-stem + `-daily-` suffix pattern as daily_puzzle.py), so the
    client's exact `active_date == today` match finds it without ambiguity.

    The serve date is the clue seed, which is what stops a repeat from being a rerun: the
    pool is finite (see the module docstring), so the same subject *will* come back around,
    and when it does it should be six differently-drawn clues in a different order rather
    than the identical card. Also means the dated daily and the undated archival copy of one
    subject are genuinely different puzzles.
    """
    row = assemble.build_whoami_row(entry, seed=date.isoformat())
    row.id = f"{row.id}-daily-{date:%Y%m%d}"
    row.content["id"] = row.id
    row.active_date = date.isoformat()
    return row


def mint_batch(
    entries: list[WhoAmIEntry], last_served: dict[tuple[str, str], str],
    targets: list[tuple[dt.date, str]],
) -> list[tuple[dt.date, WhoAmIEntry, PuzzleRow]]:
    """Pick per (date, sport) slot in order, updating `last_served` in place as it goes so a
    multi-day batch keeps rotating instead of re-picking the same stalest entry every day."""
    minted: list[tuple[dt.date, WhoAmIEntry, PuzzleRow]] = []
    for date, sport in targets:
        entry = pick_lrs_entry(entries, last_served, date, sport, tier=pick_tier(date, sport))
        if entry is None:
            print(f"[whoami] {date.isoformat()} {sport}: no entries in the pool — skipped")
            continue
        last_served[(sport, player_key(entry))] = date.isoformat()
        minted.append((date, entry, _finalize_row(date, entry)))
    return minted


def main() -> int:
    ap = argparse.ArgumentParser(description="Mint the daily Who Am I? pick per sport")
    ap.add_argument("--upsert", action="store_true", help="write the pick(s) to Supabase")
    ap.add_argument("--dry-run", action="store_true", help="pick + print, no writes")
    ap.add_argument("--date", type=str, default=None,
                    help="start date override (YYYY-MM-DD), for testing/backfill")
    ap.add_argument("--count", type=int, default=1,
                    help="mint this many consecutive days starting at --date")
    args = ap.parse_args()
    if not args.upsert and not args.dry_run:
        args.dry_run = True

    ingest_main.load_dotenv()
    start = dt.date.fromisoformat(args.date) if args.date else dt.date.today()
    target_dates = [start + dt.timedelta(days=i) for i in range(args.count)]
    targets = [(d, sport) for d in target_dates for sport in SPORTS]

    entries = whoami_pool.all_entries(ingest_main.DATA_DIR)
    tiers = Counter(whoami_clues.difficulty_of(e) for e in entries)
    print(f"[whoami] {len(entries)} pool entries loaded "
          f"({', '.join(f'{t}: {tiers[t]}' for t in whoami_clues.DIFFICULTIES)})")

    last_served: dict[tuple[str, str], str] = {}
    if args.upsert:
        from .upsert import fetch_whoami_history, upsert, upsert_whoami_history
        history = fetch_whoami_history()
        already = {(r["served_date"], r["sport"]) for r in history}
        for r in history:
            hist_key = (r["sport"], r["player_key"])
            if r["served_date"] > last_served.get(hist_key, ""):
                last_served[hist_key] = r["served_date"]
        for d, sport in targets:
            if (d.isoformat(), sport) in already:
                print(f"[whoami] {d.isoformat()} {sport} already has a pick — skipping "
                      "(idempotent, same posture as daily_puzzle.py)")
        targets = [(d, s) for d, s in targets if (d.isoformat(), s) not in already]
        if not targets:
            return 0
        print(f"[whoami] {len(history)} history rows loaded, minting {len(targets)} slot(s)")
    else:
        print("[whoami] --dry-run: skipping the whoami_history lookup (empty history)")

    minted = mint_batch(entries, last_served, targets)
    for date, entry, row in minted:
        validate(row)
        print(f"── {date.isoformat()} · {entry.sport} · {row.content['difficulty'].upper()} ── "
              f"{entry.canonical}  ({row.id})")
        for cl in row.content["clues"]:
            print(f"     {cl['order']}. [{cl['label']}] {cl['text']}")

    if not minted:
        return 1

    if args.upsert:
        sent = upsert([row for _, _, row in minted])
        print(f"[whoami] upserted {sent} puzzle row(s)")
        hist_sent = upsert_whoami_history([{
            "sport": entry.sport, "player_key": player_key(entry),
            "served_date": date.isoformat(), "puzzle_id": row.id,
        } for date, entry, row in minted])
        print(f"[whoami] recorded {hist_sent} history row(s)")
    else:
        print("(--dry-run: not written to Supabase)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
