"""Week Packs: a batch of boards about the period a league just finished, dropped together.

`fresh_drop.py` answers "what is the ONE board about this week?" and ships it as the daily.
This answers "which FIVE boards about this week work as a set?" It reuses fresh_drop's clock
and candidate themes; the new parts are the data contract in front of it and the last step.

EVERY SPORT IS ON
There is no list of sports that get packs. A league-week is pulled from `weekly.py` and judged
by `readiness.py`: a sport with no full-league weekly source, or a week that is not a real week,
SKIPs quietly; a week whose data is late or broken BLOCKs loudly; otherwise it is built.

THE OVERLAP PROBLEM
A week's best performers qualify for almost every theme. Replaying 2026 Week 1, Jahmyr Gibbs
was a KEEP on six of the twenty-one candidate boards, and "fifteen-carry games" came out as the
exact same eight players as "top RB performances". Five boards chosen independently would be
one board five times. So a pack is assembled greedily, slot by slot, under three rules:

  - a player may appear on at most MAX_APPEARANCES boards;
  - no two boards may share the same four keeps;
  - no two boards may be the same KIND of board (`fresh_drop.theme_kind`).

A "top" board cannot drop a player without its title becoming a lie, so the rules choose
between whole boards and never edit one.

PHOTOS
Every card photo must be ours (`validate.HEADSHOT_STORE_MARKER`). Provider URLs are rewritten
through the headshot ledger, this week's never-seen photos are rehosted on the spot, anything
still foreign is dropped, and a board left with fewer than MIN_PHOTOS faces is not offered.

BOARD ZERO IS THE DAILY
The first board also takes the sport's keep4 daily for the drop date, through fresh_drop's fenced
supersede, so the week reaches builds that predate packs too. Only for sports in
`validate.WIRE_SAFE_SPORTS`: a daily row in `puzzles` is read by every installed build.

    python -m tools.ingest.pack --sport nfl --dry-run
    python -m tools.ingest.pack --sport baseball --upsert
    python -m tools.ingest.pack --sport nfl --replay 2025
    python -m tools.ingest.pack --sport nba --replay-from 2026-01-05 --replay-to 2026-03-29
"""
from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import os
import random

from . import assemble, curation, fresh_drop, periods, readiness, shapes, validate, weekly
from . import main as ingest_main
from .assemble import PuzzleRow
from .baselines import compute_baselines
from .daily_puzzle import _finalize_row, _signature
from .grade import BaselineTable
from .models import RawSeason
from .periods import Period

# Slot order is priority order: when the candidate space runs thin, later slots go unfilled
# before earlier ones do.
SLOTS: tuple[str, ...] = ("headline", "game", "position", "division", "niche")
TARGET_ITEMS = len(SLOTS)
# Below this a "pack" is a daily with a sticker on it. Publish nothing; the daily still ships.
MIN_ITEMS = 3
MAX_APPEARANCES = 2
# Same recognizability bar the nightly generator holds a board to: six of eight faces.
MIN_PHOTOS = 6


@dataclasses.dataclass(frozen=True)
class Candidate:
    """One board a pack slot could hold."""
    role: str
    theme_key: str
    title: str
    row: PuzzleRow
    signature: str
    # Lower sorts first within a role before any assembly-time ordering applies.
    rank: float = 0.0
    tiebreak: float = 0.0
    position: str = ""       # position slot only: the cohort's position

    @property
    def kind(self) -> str:
        return fresh_drop.theme_kind(self.theme_key)

    @property
    def player_ids(self) -> tuple[str, ...]:
        return tuple(p["id"] for p in self.row.content["players"])

    @property
    def keep_ids(self) -> frozenset[str]:
        ranked = sorted(self.row.content["players"], key=lambda p: -p["grade"])
        return frozenset(p["id"] for p in ranked[:4])


def _role_of_flagship(theme_key: str, sport: str, period: Period) -> tuple[str, str]:
    """('headline' | 'division' | 'position', position) from a flagship key's tail."""
    lead = fresh_drop.LEAD_SPEC.get(sport, "ANY").lower()
    tail = theme_key[len(f"fresh-{sport}-{period.slice.key}-".lower()):]
    if tail == lead:
        return "headline", ""
    if tail.startswith(f"{lead}-"):
        return "division", ""
    return "position", tail.upper()


def build_candidates(sport: str, period: Period, seasons: list[RawSeason],
                     baselines: BaselineTable, rng: random.Random) -> list[Candidate]:
    """Every board this period can produce, each tagged with the slot it can fill."""
    out: list[Candidate] = []

    def add(role: str, theme, rank: float = 0.0, position: str = "") -> None:
        for row in assemble.build_keep4_rows(theme, seasons, baselines, max_variants=1):
            out.append(Candidate(role=role, theme_key=theme.key, title=theme.title, row=row,
                                 signature=_signature(theme.key, row), rank=rank,
                                 tiebreak=rng.random(), position=position))

    for theme in fresh_drop.flagship_themes(sport, period):
        role, position = _role_of_flagship(theme.key, sport, period)
        add(role, theme, position=position)

    # Game of the week: every real fixture the week can field eight players from, strongest
    # first by the combined grade of its best eight (the board a player would actually see).
    for cohort in fresh_drop.GAME_COHORTS.get(sport, ()):
        spec = curation.SPORTS[cohort].positions.get(fresh_drop.LEAD_SPEC.get(sport, "ANY"))
        if spec is None:
            continue
        for date, team_a, team_b in shapes.same_game_subjects(seasons, sport, spec.position_set):
            theme = shapes.same_game(sport, date, team_a, team_b, spec)
            top = assemble.grade_pool(theme, seasons, baselines)[:8]
            add("game", theme, rank=-sum(g for _, g in top))

    for theme in fresh_drop.rolled_period_themes(sport, period, seasons, rng):
        add("niche", theme)
    return out


def _fits(c: Candidate, served: set[str], kinds: set[str], keepsets: set[frozenset[str]],
          appearances: collections.Counter) -> bool:
    return (c.signature not in served
            and c.kind not in kinds
            and c.keep_ids not in keepsets
            and all(appearances[p] < MAX_APPEARANCES for p in c.player_ids))


def assemble_pack(candidates: list[Candidate], served: set[str] | frozenset[str] = frozenset(),
                  recent_kinds: set[str] | frozenset[str] = frozenset(),
                  positions: dict[str, str] | None = None,
                  headline: Candidate | None = None,
                  target: int = TARGET_ITEMS) -> list[Candidate]:
    """Fill SLOTS in order, each with the first candidate that still fits the pack's rules.

    Pure: no network, deterministic for a given candidate list. `positions` maps player id to
    position, so the position slot can prefer whichever position the headline's keeps left out.
    `headline` pins slot one (a fresh daily that already exists); it is taken as-is.
    """
    positions = positions or {}
    served = set(served)
    chosen: list[Candidate] = []
    kinds: set[str] = set()
    keepsets: set[frozenset[str]] = set()
    appearances: collections.Counter = collections.Counter()

    def take(c: Candidate) -> None:
        chosen.append(c)
        kinds.add(c.kind)
        keepsets.add(c.keep_ids)
        appearances.update(c.player_ids)

    if headline is not None:
        take(dataclasses.replace(headline, role="headline"))

    for role in SLOTS:
        if len(chosen) >= target:
            break
        if role == "headline" and headline is not None:
            continue
        pool = [c for c in candidates if c.role == role]
        # The cooldown leads every editorial slot's ordering. Without it the position slot's
        # "whichever position the headline's keeps left out" is nearly always TE, because top
        # performers are rarely tight ends: replaying 2025 served "top TE performances" in 11 of
        # 18 packs. Soft as everywhere else: it reorders, it never starves a slot.
        cooling = lambda c: c.kind in recent_kinds
        if role == "position":
            kept = collections.Counter(positions.get(p, "") for c in chosen for p in c.keep_ids)
            key = lambda c: (cooling(c), kept[c.position], c.tiebreak)
        elif role == "division":
            key = lambda c: (cooling(c), sum(appearances[p] for p in c.player_ids), c.tiebreak)
        elif role == "niche":
            key = lambda c: (cooling(c), c.tiebreak)
        else:
            key = lambda c: (c.rank, c.tiebreak)
        for c in sorted(pool, key=key):
            if _fits(c, served, kinds, keepsets, appearances):
                take(c)
                break
    return chosen


# ── Photos ────────────────────────────────────────────────────────────────────

def _is_ours(url: str) -> bool:
    return validate.HEADSHOT_STORE_MARKER in (url or "")


def apply_photos(candidates: list[Candidate], ledger: dict[str, str]) -> list[Candidate]:
    """Rewrite every card photo through `ledger`, drop anything still foreign, and keep only
    boards that still show MIN_PHOTOS faces. Pure; `ledger` maps a provider URL to our Storage
    URL, or to '' for a source the ledger proved is a placeholder."""
    out = []
    for c in candidates:
        players = []
        for p in c.row.content["players"]:
            card = dict(p)
            shot = ledger.get(card.get("headshot", ""), card.get("headshot", ""))
            if _is_ours(shot):
                card["headshot"] = shot
            else:
                card.pop("headshot", None)
            players.append(card)
        if sum(1 for p in players if p.get("headshot")) < MIN_PHOTOS:
            continue
        content = {**c.row.content, "players": players}
        out.append(dataclasses.replace(c, row=dataclasses.replace(c.row, content=content)))
    return out


def resolve_photos(candidates: list[Candidate], sport: str, *, rehost: bool) -> dict[str, str]:
    """The ledger entries for every photo on a candidate board, rehosting the ones the ledger has
    never seen when `rehost` (a live run). A dry run only reads."""
    from .upsert import fetch_headshot_ledger_for, record_headshot_assets
    sources = {p.get("headshot", "") for c in candidates for p in c.row.content["players"]}
    sources = {s for s in sources if s and not _is_ours(s)}
    ledger = fetch_headshot_ledger_for(sorted(sources))
    unknown = sorted(sources - ledger.keys())
    print(f"[pack] photos: {len(sources)} provider URLs on candidate boards, "
          f"{len(ledger)} in the ledger, {len(unknown)} never seen")
    if rehost and unknown:
        from concurrent.futures import ThreadPoolExecutor
        from .headshots import rehost_source
        from .upsert import _require_env
        base, key = _require_env()
        with ThreadPoolExecutor(max_workers=8) as pool:
            rows = list(pool.map(lambda u: rehost_source(base, key, u, sport, 512), unknown))
        record_headshot_assets(rows)
        for r in rows:
            if r["status"] in ("ok", "placeholder", "missing"):
                ledger[r["source_url"]] = r["public_url"] or ""
        print(f"[pack] rehosted {sum(r['status'] == 'ok' for r in rows)} new photo(s)")
    return ledger


# ── Rows ──────────────────────────────────────────────────────────────────────

def pack_id(sport: str, period: Period) -> str:
    return f"{sport}-{period.key}"


def item_rows(pid: str, items: list[Candidate], drop: dt.date,
              headline_id: str | None) -> list[dict]:
    """`pack_items` payload. Board zero is always the one that ships as the daily, and keeps the
    daily's puzzle id so one play counts for both surfaces; every other board gets a
    pack-scoped id.

    Board zero, not "the item whose role is headline": the league-wide board is invalid in a
    week whose fourth and fifth performances tie (2025 Week 6), and then the first board that
    did fit carries the daily instead."""
    out = []
    for ordinal, c in enumerate(items):
        content = dict(c.row.content)
        if ordinal == 0 and headline_id:
            item_id = headline_id
        else:
            item_id = f"{c.row.id}-pack-{drop:%Y%m%d}"
        content["id"] = item_id
        out.append({"id": item_id, "pack_id": pid, "ordinal": ordinal, "role": c.role,
                    "format": c.row.format, "theme_key": c.theme_key,
                    "signature": c.signature, "content": content})
    return out


def validate_items(rows: list[dict]) -> None:
    """The same wire contract every daily passes (`validate.validate`), applied to pack boards."""
    for r in rows:
        validate.validate(PuzzleRow(id=r["id"], sport=r["content"]["sport"], format=r["format"],
                                    content=r["content"]))


def _print_pack(pid: str, period: Period, drop: dt.date, items: list[Candidate]) -> None:
    print(f"\n══ {pid} · {period.label} · opens {drop.isoformat()} · {len(items)} boards")
    for n, c in enumerate(items):
        players = sorted(c.row.content["players"], key=lambda p: -p["grade"])
        keeps = ", ".join(p["name"] for p in players[:4])
        print(f"  {n}. [{c.role}] {c.title}")
        print(f"     keep: {keeps}")


def check_rules(items: list[Candidate]) -> list[str]:
    """Human-readable violations of the pack rules (empty when the pack is sound). Used by the
    replay and by tests as an independent re-check of `assemble_pack`."""
    problems = []
    counts = collections.Counter(p for c in items for p in c.player_ids)
    over = {p: n for p, n in counts.items() if n > MAX_APPEARANCES}
    if over:
        problems.append(f"over-exposed players: {over}")
    kinds = [c.kind for c in items]
    if len(set(kinds)) != len(kinds):
        problems.append(f"repeated board kind: {kinds}")
    keepsets = [c.keep_ids for c in items]
    if len(set(keepsets)) != len(keepsets):
        problems.append("two boards share the same four keeps")
    sigs = [c.signature for c in items]
    if len(set(sigs)) != len(sigs):
        problems.append("duplicate signature")
    return problems


def pick_replacement(candidates: list[Candidate], kept: list[Candidate], role: str,
                     served: set[str]) -> Candidate | None:
    """The first `role` board that fits beside the boards a pack keeps, under the same rules
    `assemble_pack` holds a whole pack to. Pure."""
    kinds = {c.kind for c in kept}
    keepsets = {c.keep_ids for c in kept}
    appearances = collections.Counter(p for c in kept for p in c.player_ids)
    for c in sorted((c for c in candidates if c.role == role), key=lambda c: (c.rank, c.tiebreak)):
        if _fits(c, served, kinds, keepsets, appearances):
            return c
    return None


def _candidate_from_item(item: dict) -> Candidate:
    content = item["content"]
    return Candidate(role=item["role"], theme_key=item["theme_key"], title=content.get("theme", ""),
                     row=PuzzleRow(id=item["id"], sport=content["sport"], format=item["format"],
                                   content=content),
                     signature=item["signature"])


def replace_item(sport: str, today: dt.date, ordinal: int, *, upsert: bool) -> int:
    """Swap one board of an already-published pack for the next board that fits, when nobody has
    played it. For a board that should never have shipped (the Week 1 "5.5-a-carry" deep cut),
    once the rule that let it through is fixed: the candidates are rebuilt under today's rules."""
    from .upsert import (count_results, delete_unplayed_pack_item, fetch_history_signatures,
                         fetch_pack_items, fetch_pack_signatures, upsert_pack_items)
    ingest_main.load_dotenv()
    period = periods.closed_period(sport, today)
    if period is None:
        print(f"[pack] {sport}: no closed period as of {today.isoformat()}")
        return 1
    pid = pack_id(sport, period)
    items = fetch_pack_items(pid)
    old = next((i for i in items if i["ordinal"] == ordinal), None)
    if old is None:
        print(f"[pack] {pid} has no board at ordinal {ordinal}")
        return 1
    if ordinal == 0:
        print("[pack] board zero is also a daily; replace it through the daily, not the pack")
        return 1
    plays = count_results(old["id"])
    if plays:
        print(f"[pack] {old['id']} has {plays} recorded play(s); a played board is never replaced")
        return 1
    week = prepare(sport, period)
    if not week.verdict.ready:
        print(f"[pack] {week.verdict.summary()}")
        return 1
    candidates = apply_photos(week.candidates, resolve_photos(week.candidates, sport, rehost=upsert))
    kept = [_candidate_from_item(i) for i in items if i["ordinal"] != ordinal]
    served = fetch_history_signatures() | fetch_pack_signatures()
    new = pick_replacement(candidates, kept, old["role"], served)
    if new is None:
        print(f"[pack] no {old['role']} board fits beside the other {len(kept)}; leaving it")
        return 1
    drop = dt.date.fromisoformat(fetch_pack_release(pid))
    row = item_rows(pid, [new], drop, None)[0]
    row["ordinal"] = ordinal
    validate_items([row])
    problems = check_rules(kept + [new])
    if problems:
        print(f"[pack] BUG: replacement breaks a rule: {problems}")
        return 1
    print(f"[pack] {pid} #{ordinal}: {old['content'].get('theme')!r} -> {new.title!r}")
    print("     keep: " + ", ".join(p["name"] for p in sorted(new.row.content["players"],
                                                               key=lambda p: -p["grade"])[:4]))
    if not upsert:
        print("(--dry-run: not written)")
        return 0
    delete_unplayed_pack_item(old["id"])
    upsert_pack_items([row])
    print(f"[pack] replaced {old['id']} with {row['id']}")
    return 0


def fetch_pack_release(pid: str) -> str:
    from .upsert import fetch_pack
    pack = fetch_pack(pid)
    return pack["release_date"]


# ── Pipeline ──────────────────────────────────────────────────────────────────

@dataclasses.dataclass
class Week:
    verdict: readiness.Verdict
    rows: list[RawSeason]
    candidates: list[Candidate]
    positions: dict[str, str]


def prepare(sport: str, period: Period) -> Week:
    """Pull the week, judge it, and (only when READY) build its candidate boards."""
    data = weekly.gather(sport, period)
    verdict = readiness.evaluate(sport, period, data,
                                 scorable=sport in fresh_drop.GAME_COHORTS)
    if not verdict.ready or data is None:
        return Week(verdict, data.rows if data else [], [], {})
    baselines = BaselineTable(compute_baselines(data.rows))
    rng = random.Random(f"pack-{sport}-{period.key}")
    candidates = build_candidates(sport, period, data.rows, baselines, rng)
    return Week(verdict, data.rows, candidates, {s.player_id: s.position for s in data.rows})


def _replay_periods(sport: str, season: int | None, start: str | None,
                    end: str | None) -> list[tuple[dt.date, Period]]:
    if sport == "nfl":
        from .providers import nfl_nflverse_schedule as sched
        rows = sched.fetch_rows()
        out = []
        for week, (_, last) in sorted(sched.week_windows(rows, season).items()):
            today = dt.date.fromisoformat(last) + dt.timedelta(days=1)
            period = periods.nfl_closed_week(today, rows)
            if period is not None and period.key == f"{season}-wk{week:02d}":
                out.append((today, period))
        return out
    first, last = dt.date.fromisoformat(start), dt.date.fromisoformat(end)
    out, day = [], first + dt.timedelta(days=(7 - first.weekday()) % 7 or 7)
    while day <= last + dt.timedelta(days=1):
        out.append((day, periods.rolling_week(sport, day)))
        day += dt.timedelta(days=7)
    return out


def replay(sport: str, season: int | None, start: str | None = None, end: str | None = None,
           *, photos: bool = False) -> int:
    """Dry-run every week in range, carrying novelty and cooldown forward the way the live cron
    would. Exit 1 if a READY week breaks a rule or yields fewer than MIN_ITEMS boards."""
    ingest_main.load_dotenv()
    served: set[str] = set()
    history: list[tuple[dt.date, str]] = []
    bad, sizes, verdicts = 0, [], collections.Counter()
    for today, period in _replay_periods(sport, season, start, end):
        week = prepare(sport, period)
        verdicts[week.verdict.status.value] += 1
        if not week.verdict.ready:
            print(f"\n── {pack_id(sport, period)}: {week.verdict.summary()}")
            continue
        candidates = week.candidates
        if photos and os.getenv("SUPABASE_URL"):
            candidates = apply_photos(candidates, resolve_photos(candidates, sport, rehost=False))
        since = today - dt.timedelta(days=fresh_drop.THEME_KIND_COOLDOWN_DAYS)
        items = assemble_pack(candidates, served, {k for d, k in history if d >= since},
                              week.positions)
        _print_pack(pack_id(sport, period), period, fresh_drop.target_date(today, False), items)
        problems = check_rules(items)
        if len(items) < MIN_ITEMS:
            problems.append(f"only {len(items)} boards")
        for p in problems:
            print(f"  !! {p}")
        bad += bool(problems)
        sizes.append(len(items))
        served.update(c.signature for c in items)
        history.extend((today, c.kind) for c in items)
    print(f"\n[pack] replay {sport}: verdicts {dict(verdicts)}, boards per READY pack "
          f"{dict(collections.Counter(sizes))}, {bad} week(s) with problems")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the Week Pack for the period a sport just finished")
    ap.add_argument("--sport", required=True)
    ap.add_argument("--upsert", action="store_true", help="write the pack to Supabase")
    ap.add_argument("--dry-run", action="store_true", help="build + print, no writes")
    ap.add_argument("--date", type=str, default=None,
                    help="pretend today is this date (YYYY-MM-DD)")
    ap.add_argument("--same-day", action="store_true",
                    help="open TODAY instead of tomorrow (see fresh_drop.target_date)")
    ap.add_argument("--write-fixture", type=str, default=None, metavar="PATH",
                    help="with --dry-run: write the pack as wire rows to PATH, for the app's "
                         "DEBUG -weekPackFixture launch arg")
    ap.add_argument("--replay", type=int, default=None, metavar="SEASON",
                    help="NFL: dry-run every week of SEASON and check the pack rules")
    ap.add_argument("--replay-from", type=str, default=None, metavar="DATE")
    ap.add_argument("--replay-to", type=str, default=None, metavar="DATE")
    ap.add_argument("--replay-photos", action="store_true",
                    help="apply the (read-only) photo gate during a replay")
    ap.add_argument("--replace", type=int, default=None, metavar="ORDINAL",
                    help="swap one unplayed board of the published pack for --date's period")
    args = ap.parse_args()
    if args.replace is not None:
        today = dt.date.fromisoformat(args.date) if args.date else dt.date.today()
        return replace_item(args.sport, today, args.replace, upsert=args.upsert)
    if args.replay is not None or args.replay_from:
        return replay(args.sport, args.replay, args.replay_from, args.replay_to,
                      photos=args.replay_photos)
    if not args.upsert and not args.dry_run:
        args.dry_run = True

    ingest_main.load_dotenv()
    today = dt.date.fromisoformat(args.date) if args.date else dt.date.today()
    period = periods.closed_period(args.sport, today)
    if period is None:
        print(f"[pack] {args.sport}: no closed period as of {today.isoformat()}. Nothing to do.")
        return 0

    drop = fresh_drop.target_date(today, args.same_day)
    pid = pack_id(args.sport, period)
    print(f"[pack] {pid}: {period.label} closed as of {today.isoformat()}; opens {drop.isoformat()}")

    tables = True
    if args.upsert:
        from .upsert import fetch_pack, packs_available
        tables = packs_available()
        if not tables:
            print("[pack] the packs tables don't exist yet (migration 0028). Shipping the "
                  "week's daily only.")
        else:
            existing = fetch_pack(pid)
            if existing and existing["status"] != "draft":
                print(f"[pack] {pid} is already {existing['status']}. A published pack is never "
                      "rebuilt: players may be partway through it.")
                return 0

    week = prepare(args.sport, period)
    print(f"[pack] readiness {week.verdict.summary()}")
    if week.verdict.status is readiness.Status.SKIP:
        return 0
    if week.verdict.status is readiness.Status.BLOCKED:
        # Loud on purpose: late or broken data upstream. The evergreen daily stays in place,
        # and a re-dispatch once the feed catches up builds the week normally.
        return 1
    candidates = week.candidates
    print(f"[pack] {len(week.rows)} event rows, {len(candidates)} candidate boards "
          f"({dict(collections.Counter(c.role for c in candidates))})")

    if os.getenv("SUPABASE_URL"):
        before = len(candidates)
        candidates = apply_photos(candidates, resolve_photos(candidates, args.sport,
                                                             rehost=args.upsert))
        print(f"[pack] photo gate kept {len(candidates)} of {before} boards "
              f"(need {MIN_PHOTOS} of 8 faces from our store)")
    elif args.upsert:
        print("[pack] SUPABASE_URL is required to write")
        return 1
    else:
        print("[pack] no Supabase env: skipping the photo gate for this dry run")

    served: set[str] = set()
    recent_kinds: set[str] = set()
    headline: Candidate | None = None
    if args.upsert:
        from .upsert import (fetch_daily_keep4, fetch_history_signatures,
                             fetch_pack_signatures, fetch_recent_theme_keys, fetch_rows_by_id)
        served = fetch_history_signatures() | (fetch_pack_signatures() if tables else set())
        since = (today - dt.timedelta(days=fresh_drop.THEME_KIND_COOLDOWN_DAYS)).isoformat()
        recent_kinds = {fresh_drop.theme_kind(k)
                        for k in fetch_recent_theme_keys(since).get(args.sport, set())}
        daily = fetch_daily_keep4(drop.isoformat(), args.sport)
        if daily and daily["theme_key"].startswith(f"fresh-{args.sport}-{period.slice.key}"):
            rows = fetch_rows_by_id("puzzles", "id,sport,format,content", [daily["puzzle_id"]])
            if rows:
                r = rows[0]
                reused = Candidate(
                    role="headline", theme_key=daily["theme_key"], title=r["content"]["theme"],
                    row=PuzzleRow(id=r["id"], sport=r["sport"], format=r["format"],
                                  content=r["content"], active_date=drop.isoformat()),
                    signature=daily["signature"])
                photographed = apply_photos([reused], resolve_photos([reused], args.sport,
                                                                     rehost=True))
                if photographed:
                    headline = photographed[0]
                    served.discard(headline.signature)
                    print(f"[pack] reusing this week's existing daily as the headline: {r['id']}")

    items = assemble_pack(candidates, served, recent_kinds, week.positions, headline=headline)
    _print_pack(pid, period, drop, items)
    for problem in check_rules(items):
        print(f"[pack] BUG: assembled pack breaks a rule: {problem}")
        return 1
    thin = len(items) < MIN_ITEMS
    if args.write_fixture and items:
        import json
        daily_id = _finalize_row(drop, None, dataclasses.replace(
            items[0].row, content=dict(items[0].row.content))).id
        fixture = {"packs": [{"id": pid, "sport": args.sport, "label": period.label,
                              "release_date": drop.isoformat()}],
                   "items": item_rows(pid, items, drop, daily_id)}
        with open(args.write_fixture, "w", encoding="utf-8") as f:
            json.dump(fixture, f, indent=1)
        print(f"[pack] wrote fixture to {args.write_fixture}")
    if not args.upsert:
        if thin:
            print(f"[pack] only {len(items)} board(s) fit the rules (minimum {MIN_ITEMS}): "
                  "a live run would ship the first board as the daily and no pack.")
        print("\n(--dry-run: not written to Supabase)")
        return 0
    if not items:
        print("[pack] nothing viable this week. Leaving the evergreen daily in place.")
        return 0

    from .upsert import (delete_draft_pack_items, publish_pack, upsert, upsert_history,
                         upsert_pack, upsert_pack_items)
    lead = items[0]
    ships_daily = headline is None and args.sport in validate.WIRE_SAFE_SPORTS
    daily_row: PuzzleRow | None = None
    if headline is not None:
        headline_id = headline.row.id
    elif ships_daily:
        daily_row = _finalize_row(drop, None, dataclasses.replace(lead.row,
                                                                 content=dict(lead.row.content)))
        validate.validate(daily_row)
        headline_id = daily_row.id
    else:
        headline_id = None

    publishes = tables and not thin
    if publishes:
        payload = item_rows(pid, items, drop, headline_id)
        validate_items(payload)
        upsert_pack({"id": pid, "sport": args.sport, "period_key": period.key,
                     "label": period.label, "release_date": drop.isoformat(), "status": "draft"})
        cleared = delete_draft_pack_items(pid)
        if cleared:
            print(f"[pack] cleared {cleared} item(s) left by an earlier unfinished run")
        upsert_pack_items(payload)

    # The daily goes out even on a thin week or before the tables exist: that is what fresh_drop
    # did before packs, and a pack failing its own bar must not cost the sport its fresh board.
    if daily_row is not None:
        removed = fresh_drop.supersede(drop, args.sport, keep_id=headline_id, today=today)
        print(f"[pack] superseded {removed} evergreen row(s) for {drop.isoformat()}")
        upsert([daily_row])
        upsert_history([{"signature": lead.signature, "theme_key": lead.theme_key,
                         "sport": args.sport, "format": "keep4", "puzzle_id": headline_id,
                         "served_date": drop.isoformat()}])

    if not publishes:
        why = "the tables don't exist yet" if not tables else \
            f"only {len(items)} board(s) fit the rules (minimum {MIN_ITEMS})"
        print(f"[pack] no pack this week: {why}. Daily shipped: {daily_row is not None}.")
        return 0
    publish_pack(pid)
    print(f"[pack] published {pid}: {len(items)} boards, daily {headline_id or 'not shipped'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
