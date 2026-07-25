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

from . import assemble
from . import main as ingest_main
from .assemble import PuzzleRow
from .daily_puzzle import SPORTS
from .models import WhoAmIEntry, slug
from .validate import validate


def player_key(entry: WhoAmIEntry) -> str:
    """Stable identity for history bookkeeping — the slug of the canonical answer name."""
    return slug(entry.canonical)


def pick_lrs_entry(
    entries: list[WhoAmIEntry], last_served: dict[tuple[str, str], str],
    today: dt.date, sport: str,
) -> WhoAmIEntry | None:
    """The least-recently-served entry for `sport` (never-served first), tie-broken by a
    per-(day, sport)-seeded shuffle so same-recency entries rotate in a varied but
    reproducible order. `last_served` maps (sport, player_key) -> most recent served_date
    (ISO string, so lexicographic order IS chronological; "" sorts before every real date).
    """
    pool = [e for e in entries if e.sport == sport]
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
    client's exact `active_date == today` match finds it without ambiguity."""
    row = assemble.build_whoami_row(entry)
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
        entry = pick_lrs_entry(entries, last_served, date, sport)
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

    entries = assemble.load_whoami_entries(ingest_main.DATA_DIR / "whoami_facts.json")
    print(f"[whoami] {len(entries)} pool entries loaded")

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
        print(f"── {date.isoformat()} · {entry.sport} ── {entry.canonical}  ({row.id})")

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
