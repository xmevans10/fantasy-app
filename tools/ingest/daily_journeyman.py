"""Mint the canonical Journeyman pick for each sport per day — least-recently-served.

A straight port of `daily_whoami.py`, and deliberately so: the two formats have the same
content shape (a finite pool of one-player subjects, rotated) and therefore the same honest
answer to "what do we serve today". Per (date, sport) it draws a difficulty tier from
`TIER_WEIGHTS`, then takes the entry served longest ago within that tier (never-served first),
tie-broken by a per-day deterministic shuffle. `journeyman_history` is the audit trail and the
idempotency key: a (date, sport) slot that already has a row is skipped, so a retried run can't
mint a second competing pick.

Unlike Who Am I?, the serve date is **not** a content seed — a career path has nothing random
in it, so a subject coming back around is genuinely the same board. The least-recently-served
ordering is what keeps that honest: with a 150-entry pool per sport at one serve a day, a
subject is over four months stale before it can return.

Examples:
    python -m tools.ingest.daily_journeyman --dry-run
    python -m tools.ingest.daily_journeyman --upsert
    python -m tools.ingest.daily_journeyman --upsert --count 3
"""
from __future__ import annotations

import argparse
import datetime as dt
import random
from collections import Counter

from . import journeyman
from . import main as ingest_main
from .assemble import PuzzleRow
from .journeyman import JourneymanEntry
from .whoami_clues import DIFFICULTIES

# Sports with clubs to move between. Not `daily_puzzle.SPORTS` — tennis has no clubs (its
# `team_abbr` is a country code), so it can never have a Journeyman daily.
SPORTS = sorted(journeyman.MIN_STINTS)

# Same shape and rationale as `daily_whoami.TIER_WEIGHTS`: a hard board roughly every fifth
# day, so the tier is a real part of the game without making most mornings a wall.
TIER_WEIGHTS: dict[str, float] = {"easy": 0.4, "medium": 0.4, "hard": 0.2}


def player_key(entry: JourneymanEntry) -> str:
    """Stable identity for history bookkeeping — the slug of the canonical answer name."""
    return entry.key


def pick_tier(today: dt.date, sport: str) -> str:
    rng = random.Random(f"journeyman-tier-{sport}-{today.isoformat()}")
    tiers = list(TIER_WEIGHTS)
    return rng.choices(tiers, weights=[TIER_WEIGHTS[t] for t in tiers], k=1)[0]


def pick_lrs_entry(entries: list[JourneymanEntry], last_served: dict[tuple[str, str], str],
                   today: dt.date, sport: str, tier: str | None = None) -> JourneymanEntry | None:
    """The least-recently-served entry for `sport` (never-served first), tie-broken by a
    per-(day, sport)-seeded shuffle. `last_served` maps (sport, player_key) -> the most recent
    served date as an ISO string, so lexicographic order IS chronological and "" sorts first.

    A tier with no entries for this sport falls back to the sport's full pool: a board of the
    wrong difficulty beats no daily at all.
    """
    pool = [e for e in entries if e.sport == sport]
    if tier:
        in_tier = [e for e in pool if e.difficulty == tier]
        if in_tier:
            pool = in_tier
        else:
            print(f"[journeyman] {today.isoformat()} {sport}: no {tier} entries — "
                  "drawing from the full pool for this sport")
    if not pool:
        return None
    rng = random.Random(f"journeyman-{sport}-{today.isoformat()}")
    order = list(range(len(pool)))
    rng.shuffle(order)
    rank = {idx: r for r, idx in enumerate(order)}
    ranked = sorted(range(len(pool)),
                    key=lambda i: (last_served.get((sport, player_key(pool[i])), ""), rank[i]))
    return pool[ranked[0]]


def _finalize_row(date: dt.date, entry: JourneymanEntry) -> PuzzleRow:
    """The dated daily row — its own row, separate from the undated archival copy of the same
    subject (`journeyman.py --upsert`), so the client's exact `active_date == today` match finds
    it unambiguously. Same id-stem + `-daily-` suffix pattern as the other two formats."""
    row = journeyman.build_row(entry, suffix=f"-daily-{date:%Y%m%d}")
    row.active_date = date.isoformat()
    return row


def mint_batch(entries: list[JourneymanEntry], last_served: dict[tuple[str, str], str],
               targets: list[tuple[dt.date, str]]) -> list[tuple[dt.date, JourneymanEntry, PuzzleRow]]:
    """Pick per (date, sport) slot in order, updating `last_served` in place as it goes so a
    multi-day batch keeps rotating instead of re-picking the same stalest entry every day."""
    minted: list[tuple[dt.date, JourneymanEntry, PuzzleRow]] = []
    for date, sport in targets:
        entry = pick_lrs_entry(entries, last_served, date, sport, tier=pick_tier(date, sport))
        if entry is None:
            print(f"[journeyman] {date.isoformat()} {sport}: no entries in the pool — skipped")
            continue
        last_served[(sport, player_key(entry))] = date.isoformat()
        minted.append((date, entry, _finalize_row(date, entry)))
    return minted


def main() -> int:
    ap = argparse.ArgumentParser(description="Mint the daily Journeyman pick per sport")
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

    entries = journeyman.all_entries(ingest_main.DATA_DIR)
    tiers = Counter(e.difficulty for e in entries)
    print(f"[journeyman] {len(entries)} pool entries loaded "
          f"({', '.join(f'{t}: {tiers[t]}' for t in DIFFICULTIES)})")

    last_served: dict[tuple[str, str], str] = {}
    if args.upsert:
        from .upsert import fetch_journeyman_history, upsert, upsert_journeyman_history
        history = fetch_journeyman_history()
        already = {(r["served_date"], r["sport"]) for r in history}
        for r in history:
            hist_key = (r["sport"], r["player_key"])
            if r["served_date"] > last_served.get(hist_key, ""):
                last_served[hist_key] = r["served_date"]
        for d, sport in targets:
            if (d.isoformat(), sport) in already:
                print(f"[journeyman] {d.isoformat()} {sport} already has a pick — skipping "
                      "(idempotent, same posture as daily_whoami.py)")
        targets = [(d, s) for d, s in targets if (d.isoformat(), s) not in already]
        if not targets:
            return 0
        print(f"[journeyman] {len(history)} history rows loaded, minting {len(targets)} slot(s)")
    else:
        print("[journeyman] --dry-run: skipping the journeyman_history lookup (empty history)")

    minted = mint_batch(entries, last_served, targets)
    from .validate import validate
    for date, entry, row in minted:
        validate(row)
        print(f"── {date.isoformat()} · {entry.sport} · {entry.difficulty.upper()} ── "
              f"{entry.canonical}  ({row.id})")
        for s in row.content["stints"]:
            years = (f"{s['firstYear']}" if s["firstYear"] == s["lastYear"]
                     else f"{s['firstYear']}-{s['lastYear']}")
            print(f"     {s['order']}. {s['teamName']} ({s['teamAbbr']}) {years}")

    if not minted:
        return 1

    if args.upsert:
        sent = upsert([row for _, _, row in minted])
        print(f"[journeyman] upserted {sent} puzzle row(s)")
        hist_sent = upsert_journeyman_history([{
            "sport": entry.sport, "player_key": player_key(entry),
            "served_date": date.isoformat(), "puzzle_id": row.id,
        } for date, entry, row in minted])
        print(f"[journeyman] recorded {hist_sent} history row(s)")
    else:
        print("(--dry-run: not written to Supabase)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
