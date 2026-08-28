"""Mint a Keep4 puzzle ABOUT the competitive period a sport just finished.

The nightly mint (`daily_puzzle.py`) answers "what is a novel puzzle?" out of the whole of
recorded history. This one answers a different question: "what just happened?" It runs on each
sport's own clock (see `periods.closed_period`), pulls only that sport's window instead of the
25-to-30 minute whole-world pull, and supersedes the evergreen puzzle already sitting on the
drop date.

Mint-then-supersede, deliberately, rather than having the nightly job skip a sport on its drop
day: if this run fails, the sport still has the evergreen daily the nightly job already minted.
Pre-empting would mean a failed run leaves a sport with no puzzle at all, which is the worst
failure available. The cost is one delete, fenced three ways (see `supersede`).

    python -m tools.ingest.fresh_drop --sport nfl --dry-run
    python -m tools.ingest.fresh_drop --sport nfl --upsert --supersede
    python -m tools.ingest.fresh_drop --sport nfl --dry-run --date 2024-09-10
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import random
import re

from . import assemble, curation, generate, periods
from . import main as ingest_main
from .assemble import PuzzleRow
from .baselines import compute_baselines
from .daily_puzzle import _finalize_row, _print_pick, _signature, pick_novel_puzzle
from .grade import BaselineTable
from .models import RawSeason
from .periods import Period
from .themes import StatColumn, Theme

# How often the plain flagship board ("2026 Week 3: top WR performances") is preferred outright
# over every rolled niche. The period IS the hook here; a niche stacked on top of it is usually
# noise, and the reference catalogue this format is modelled on carries at most one qualifier
# per title. Seeded per period, so a re-dispatched run for the same week resolves identically.
SIMPLE_SHARE = 0.55

# Rolled themes to look for on top of the flagship set, and the roll budget. Much smaller
# than the nightly mint's 60/500: the pool here is ONE week of ONE sport, so most rolls miss
# on pool size no matter how many are spent, and the flagship themes below are the floor.
ROLL_THEMES = 12
ROLL_ATTEMPTS = 120

# Cohort key per sport for the game-grain generator config (see curation.SPORTS).
GAME_COHORTS: dict[str, tuple[str, ...]] = {
    "nfl": ("nfl-games",),
}

# Division slices available as flagship boards, per sport.
DIVISIONS: dict[str, tuple[curation.Slice, ...]] = {
    "nfl": curation.division_slices(curation.NFL_DIVISIONS),
}


def flagship_themes(sport: str, period: Period) -> list[Theme]:
    """The editorial floor: themes a period is guaranteed to be able to try, whatever the
    rolls do. Without these a quiet week where every rolled quirk misses would mint nothing
    and silently fall back to the evergreen puzzle, which is the one outcome that makes the
    whole feature invisible.

    `window_mode="top"` on all of them, because a board titled "Top Performances" that served
    a grade-adjacent window from the middle of the pool would be lying in its own title.
    """
    cohorts = [curation.SPORTS[key] for key in GAME_COHORTS.get(sport, ())]
    out: list[Theme] = []
    for cfg in cohorts:
        for spec_key, spec in cfg.positions.items():
            label = "performances" if spec_key == "ANY" else f"{spec.label} performances"
            out.append(_flagship(cfg, spec, spec_key, period,
                                 f"{period.label}: top {label}", ""))
        # Division boards, the reference catalogue's other plain shape ("All-Time AFC East
        # Seasons" and its seven siblings are 21% of that sample). They also fix a real
        # thinness problem: with only one flagship per position, a season of mostly-plain
        # drops repeats "top QB performances" every few weeks. Cross-positional only, since a
        # single division in a single week is four clubs and a per-position cut of that is too
        # thin to field eight.
        any_spec = cfg.positions.get("ANY")
        if any_spec is not None:
            for div in DIVISIONS.get(cfg.sport, ()):
                out.append(_flagship(
                    cfg, any_spec, f"ANY-{div.key}", period,
                    f"{period.label}: top performances{div.suffix}", div.key,
                    extra=div.filters))
    return out


def _flagship(cfg, spec, spec_key: str, period: Period, title: str, suffix_key: str,
              extra: tuple = ()) -> Theme:
    key = f"fresh-{cfg.sport}-{period.slice.key}-{spec_key}".lower()
    return Theme(
        key=key, title=title, sport=cfg.sport, scale=spec.scale,
        positions=spec.position_set, min_stats=dict(spec.min_stats),
        columns=list(spec.columns), filters=period.slice.filters + extra,
        grain=spec.grain, pool_cap=spec.pool_cap, window_mode="top",
    )


def rolled_period_themes(sport: str, period: Period, seasons: list[RawSeason],
                         rng: random.Random) -> list[Theme]:
    """Rolled niche themes with the period slice forced on as the outermost axis.

    The roller is never given a period probability of its own (`generate.roll_spec` has no
    P_PERIOD): a randomly rolled "2019 Week 7" is not interesting, because recency is only
    interesting when it is actually recent. Injecting the slice here is what keeps the
    nightly mint's behaviour completely unchanged by this feature.
    """
    out: list[Theme] = []
    for key in GAME_COHORTS.get(sport, ()):
        cfg = curation.SPORTS[key]
        # Era slices are stripped, not merely deprioritised. A decade ANDed onto a single week
        # is redundant at best and unreadable at worst: the first replay of a 2024 season
        # produced "2024 Week 18: 2020s Under-24 player games", which states the decade twice
        # and buries the actual hook. `teams=()` does the same job for the club axis.
        cfg = dataclasses.replace(cfg, slices=())
        for theme in generate.roll_viable_themes(cfg, seasons, rng, ROLL_THEMES,
                                                 ROLL_ATTEMPTS, teams=(), label=key):
            out.append(_with_period(theme, period))
    return out


# A period key inside a theme key: '2026-wk03' or '2026-08-17-to-2026-08-23'.
_PERIOD_KEY = re.compile(r"-\d{4}-(?:wk\d{2}|\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2})-")


# How long a KIND of board stays on the bench for a sport. Shorter than the nightly mint's 21
# days because a period cohort is much smaller: with roughly a dozen viable rolls a week, a
# three-week bench is most of the space, and the cooldown is a soft ranking penalty anyway.
THEME_KIND_COOLDOWN_DAYS = 14


def _kind_of(theme: Theme) -> str:
    return theme_kind(theme.key)


def theme_kind(key: str) -> str:
    """A period theme's key with the period removed, i.e. what KIND of board it is.

    `puzzle_history`'s 21-day theme cooldown keys on the whole theme key, and every period
    produces a different one, so the cooldown can never fire on a fresh drop. Left alone that
    is not a hypothetical: replaying 2024 minted "undrafted player gems" in weeks 10, 12 and
    17, and "under-24 player games" in back-to-back weeks 15 and 16. Signature novelty was
    intact every time (never the same eight cards), but a player reads the title.
    """
    return _PERIOD_KEY.sub("-", key, count=1)


def _with_period(theme: Theme, period: Period) -> Theme:
    """AND the period onto a rolled theme, composing key and title the same way
    `generate.roll_theme` composes any other outermost slice, so the two paths stay
    key-compatible for `puzzle_history`'s cooldown."""
    import dataclasses
    sl = period.slice
    return dataclasses.replace(
        theme,
        key=f"{theme.key.split('-', 1)[0]}-{sl.key}-{theme.key.split('-', 1)[1]}".lower(),
        title=sl.prefix + theme.title[0].lower() + theme.title[1:],
        filters=sl.filters + theme.filters,
    )


def gather_period(sport: str, period: Period) -> list[RawSeason]:
    """Only the rows the period needs. This is the whole reason a same-morning drop is
    possible: `main.gather_seasons()` pulls every sport's entire history (25-30 min), and a
    week of one sport is one cached file.

    Returns [] for a sport whose event-grain pull is not wired yet, which the caller treats
    the same as "nothing to mint".
    """
    if sport != "nfl":
        return []
    from .providers import nfl_nflverse_games
    rows = nfl_nflverse_games.fetch_years([period.season_year])
    window = [r for r in rows if period.start <= (r.event_date or "") <= period.end]
    ingest_main.merge_nfl_bio(window)     # bio quirks (draft round, height, age) need this
    return window


def build_candidates(sport: str, period: Period, seasons: list[RawSeason],
                     baselines: BaselineTable,
                     rng: random.Random) -> list[tuple[Theme, PuzzleRow]]:
    """Every (theme, window) pair this period can produce. Rolled niches first, flagships
    last, mirroring `daily_puzzle.build_candidates` so `pick_novel_puzzle`'s ranking (which
    depends on that order) behaves identically here."""
    pairs: list[tuple[Theme, PuzzleRow]] = []
    themes = [*rolled_period_themes(sport, period, seasons, rng),
              *flagship_themes(sport, period)]
    for theme in themes:
        for row in assemble.build_keep4_rows(theme, seasons, baselines, max_variants=4):
            pairs.append((theme, row))
    return pairs


def target_date(today: dt.date, same_day: bool) -> dt.date:
    """Which local calendar date this drop claims.

    Tomorrow by default, and that is a hard timezone constraint rather than caution: the
    client keys a daily to the DEVICE-LOCAL date, and UTC+14 reaches tomorrow's midnight at
    10:00 UTC today. A job running Tuesday morning UTC cannot claim Tuesday without swapping
    the puzzle out from under everyone who is already in Tuesday. For NFL that makes the real
    cadence "Monday night closes the week, the puzzle lands Wednesday local".

    `--same-day` exists for when trading the UTC+12-and-later players' mid-day swap for a
    same-day US drop is a decision someone has actually made. It is not the default.
    """
    return today if same_day else today + dt.timedelta(days=1)


def supersede(date: dt.date, sport: str, keep_id: str, *, today: dt.date) -> int:
    """Remove the evergreen puzzle this drop replaces, so `puzzle_history`'s
    unique(served_date, sport, format) still holds and the client sees exactly one.

    The only destructive operation in the fresh-drop path, fenced three ways: it never runs
    without `--supersede`; it refuses any date that is not strictly in the future, so a day
    someone may already have played can never be rewritten; and it names every row it removes
    in the log.
    """
    if date <= today:
        print(f"[fresh] REFUSING to supersede {date.isoformat()}: not strictly in the future. "
              "A puzzle for today or earlier may already have been played.")
        return 0
    from .upsert import delete_daily_keep4
    return delete_daily_keep4(date.isoformat(), sport, keep_id=keep_id)


def main() -> int:
    ap = argparse.ArgumentParser(description="Mint a puzzle about the period a sport just finished")
    ap.add_argument("--sport", required=True, help="nfl | nba | baseball | soccer | tennis")
    ap.add_argument("--upsert", action="store_true", help="write the pick to Supabase")
    ap.add_argument("--dry-run", action="store_true", help="build + pick + print, no writes")
    ap.add_argument("--date", type=str, default=None,
                    help="pretend today is this date (YYYY-MM-DD) — for replay and tests")
    ap.add_argument("--supersede", action="store_true",
                    help="remove the evergreen puzzle already minted for the drop date")
    ap.add_argument("--same-day", action="store_true",
                    help="claim TODAY instead of tomorrow (see target_date for the tradeoff)")
    args = ap.parse_args()
    if not args.upsert and not args.dry_run:
        args.dry_run = True

    ingest_main.load_dotenv()
    today = dt.date.fromisoformat(args.date) if args.date else dt.date.today()

    period = periods.closed_period(args.sport, today)
    if period is None:
        print(f"[fresh] {args.sport}: no closed period as of {today.isoformat()} "
              "(out of season, or the current one is still being played). Nothing to do.")
        return 0
    if not period.wired:
        print(f"[fresh] {args.sport}: period {period.label} detected, but this sport's "
              "event-grain pull is not wired yet (see periods.WIRED). Nothing to do.")
        return 0

    drop = target_date(today, args.same_day)
    print(f"[fresh] {args.sport}: {period.label} ({period.start} to {period.end}) "
          f"closed as of {today.isoformat()}; drop date {drop.isoformat()}")

    seasons = gather_period(args.sport, period)
    print(f"[fresh] {len(seasons)} event rows in the window")
    if not seasons:
        print("[fresh] no rows for the period. Leaving the evergreen daily in place.")
        return 0

    baselines = BaselineTable(compute_baselines(seasons))
    rng = random.Random(f"fresh-{args.sport}-{period.key}")
    candidates = build_candidates(args.sport, period, seasons, baselines, rng)
    print(f"[fresh] {len(candidates)} candidate (theme, window) pairs")
    if not candidates:
        print("[fresh] nothing viable built for this period. Leaving the evergreen daily in "
              "place — a thin week must never blank a sport's day.")
        return 0

    recent_kinds: set[str] = set()
    if args.upsert:
        from .upsert import fetch_history_signatures, fetch_recent_theme_keys
        served = fetch_history_signatures()
        since = (today - dt.timedelta(days=THEME_KIND_COOLDOWN_DAYS)).isoformat()
        recent_kinds = {theme_kind(k)
                        for k in fetch_recent_theme_keys(since).get(args.sport, set())}
        print(f"[fresh] {len(served)} signatures served; {len(recent_kinds)} theme kind(s) "
              f"on cooldown since {since}")
    else:
        served = set()
        print("[fresh] --dry-run: starting from an empty served-signature history")

    # A seeded coin, not `random`: the same week must resolve the same way on a retry.
    prefer_simple = random.Random(f"simple-{args.sport}-{period.key}").random() < SIMPLE_SHARE
    tier = (lambda t: 0 if t.key.startswith("fresh-") else 1) if prefer_simple \
        else (lambda t: 0 if t.key.startswith("gen") else 1)
    print(f"[fresh] tier: {'plain flagship board first' if prefer_simple else 'niche first'}")
    pick = pick_novel_puzzle(candidates, served, drop, recent_kinds,
                             cooldown_key=_kind_of, tier_key=tier)
    if pick is None:
        print("[fresh] every candidate for this period was already served. Leaving the "
              "evergreen daily in place.")
        return 0
    theme, row, sig = pick
    row = _finalize_row(drop, theme, row)
    _print_pick(drop, theme, row)

    if not args.upsert:
        print("\n(--dry-run: not written to Supabase)")
        return 0

    from .upsert import upsert, upsert_history
    if args.supersede:
        removed = supersede(drop, args.sport, keep_id=row.id, today=today)
        print(f"[fresh] superseded {removed} evergreen row(s) for {drop.isoformat()}")
    sent = upsert([row])
    hist = upsert_history([{
        "signature": sig, "theme_key": theme.key, "sport": theme.sport,
        "format": "keep4", "puzzle_id": row.id, "served_date": drop.isoformat(),
    }])
    print(f"[fresh] upserted {sent} puzzle row(s), {hist} history row(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
