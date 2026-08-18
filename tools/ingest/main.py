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
from collections import Counter
from pathlib import Path

from . import assemble, generate, health, whoami_pool
from .assemble import PuzzleRow
from .baselines import compute_baselines
from .career import build_career_rows
from .grade import BaselineTable, grade
from .models import RawSeason
from .providers import (
    api_football,
    bref_nba,
    espn_nba,
    espn_nba_pool,
    espn_soccer,
    hoopr_nba,
    hoopr_nba_games,
    mlb_pool,
    mlb_stats,
    mlb_stats_games,
    nba_balldontlie,
    nfl_history,
    nfl_nflverse,
    nfl_nflverse_defense,
    nfl_nflverse_games,
    nfl_players,
    seed,
    tennis_atp,
    tennis_recent,
    tennis_wta,
    transfermarkt_soccer,
)
from .themes import KEEP4_THEMES, export_themes
from .validate import validate

ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = Path(__file__).resolve().parent / "data"
FALLBACK_KEEP4 = ROOT / "BallIQ" / "Data" / "keep4_puzzles.json"
FALLBACK_WHOAMI = ROOT / "BallIQ" / "Data" / "whoami_puzzles.json"
FALLBACK_CATALOG = ROOT / "BallIQ" / "Data" / "player_seasons.json"
FALLBACK_BASELINES = ROOT / "BallIQ" / "Data" / "stat_baselines.json"
FALLBACK_THEMES = ROOT / "BallIQ" / "Data" / "keep4_themes.json"
CONTENT_HEALTH = Path(__file__).resolve().parent / "content_health.json"

# Computed from today's date, not a hardcoded literal, so this never silently goes stale —
# a fixed `range(1999, 2024)` quietly stopped covering new seasons the moment 2024 shipped.
# `nfl_nflverse.fetch_years` already skips any year whose file 404s (e.g. the current season
# before nflverse has published its aggregate), so reaching one year past "now" is safe: it
# costs one skipped request until the data exists, then picks it up with no code change.
_CURRENT_YEAR = dt.date.today().year
DEFAULT_NFL_YEARS = list(range(1999, _CURRENT_YEAR + 1))  # nflverse's full history (1999+)
# Weekly files are ~17k rows/season (vs. one row/season-aggregate), so game grain is
# bounded to a recent window by default to keep cache/fetch time sane.
DEFAULT_GAME_YEARS = list(range(_CURRENT_YEAR - 15, _CURRENT_YEAR + 1))

# NBA seasons to refresh live (the curated seed defines the target player-seasons).
NBA_LIVE_TARGETS = [(r.name, r.season_year) for r in seed.load_nba()]

# MLB person ids to always pull live (verified against statsapi.mlb.com), regardless of
# whether the discovered pool (`mlb_player_ids.json`) is present — these guarantee the
# marquee current stars are covered. The broad pool is unioned on top when available.
# fetch_by_ids pulls a player's FULL career (hitting + pitching) in one shot per
# group, so this list only needs one id per player, not one per season.
MLB_LIVE_TARGETS: dict[str, str] = {
    "592450": "Aaron Judge", "660271": "Shohei Ohtani", "605141": "Mookie Betts",
    "543037": "Gerrit Cole", "594798": "Jacob deGrom", "545361": "Mike Trout",
    "660670": "Ronald Acuña Jr.", "518692": "Freddie Freeman", "669203": "Corbin Burnes",
    "608070": "José Ramírez", "621566": "Matt Olson", "670541": "Yordan Alvarez",
    "677594": "Julio Rodríguez", "554430": "Zack Wheeler", "675911": "Spencer Strider",
    "645261": "Sandy Alcantara", "434378": "Justin Verlander", "453286": "Max Scherzer",
    "477132": "Clayton Kershaw", "677951": "Bobby Witt Jr.", "665742": "Juan Soto",
    "624413": "Pete Alonso", "694973": "Paul Skenes",
}


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


def merge_nfl_bio(seasons: list[RawSeason]) -> None:
    """Join nflverse `players.csv` bio onto each NFL season's `meta` (by gsis id), and
    compute per-season `age` from birth year. In place — `meta` is a mutable bag by design.
    Also backfills `headshot` from the same registry when the season row's own
    `headshot_url` was blank (common for older/retired seasons — see `nfl_players`
    docstring); `RawSeason` is otherwise frozen, hence `object.__setattr__`.
    Best-effort: if the bio file is unreachable, niche bio-filters just match nothing."""
    try:
        bio = nfl_players.load_bio()
    except Exception as err:  # noqa: BLE001
        print(f"[nfl] bio join skipped ({err})")
        return
    joined = 0
    headshots_backfilled = 0
    for s in seasons:
        if s.sport != "nfl":
            continue
        fields = bio.get(s.meta.get("gsis_id", ""))
        if not fields:
            continue
        fields = dict(fields)
        headshot = fields.pop("headshot", "")
        s.meta.update(fields)
        if by := fields.get("birth_year"):
            s.meta["age"] = str(s.season_year - int(by))
        if not s.headshot and headshot:
            object.__setattr__(s, "headshot", headshot)
            headshots_backfilled += 1
        joined += 1
    print(f"[nfl] bio joined onto {joined} player-seasons "
          f"({headshots_backfilled} headshots backfilled from the bio registry)")


def backfill_nfl_headshots_by_name(seasons: list[RawSeason]) -> None:
    """Last-resort headshot join by NAME for rows with no gsis_id at all — the 1970-98
    history provider and the curated seed, which is where the remaining ~2,700 blank NFL
    headshots lived (user directive 2026-07-18: no blank headshots). Era-checked and
    ambiguity-safe via `pick_headshot` (a wrong photo is worse than no photo). Runs as its
    own pass AFTER the history sweep is unioned in — `merge_nfl_bio` runs before it, so a
    join there silently missed every history row (0 filled on the first live run)."""
    try:
        by_name = nfl_players.load_headshots_by_name()
    except Exception as err:  # noqa: BLE001
        print(f"[nfl] name-based headshot join skipped ({err})")
        return
    name_filled = 0
    for s in seasons:
        if s.sport != "nfl" or s.headshot:
            continue
        if candidates := by_name.get(s.name):
            if headshot := nfl_players.pick_headshot(candidates, s.season_year):
                object.__setattr__(s, "headshot", headshot)
                name_filled += 1
    print(f"[nfl] {name_filled} headshots joined by name+era (no gsis_id rows)")


def derive_nba_totals(seasons: list[RawSeason]) -> None:
    """Bake NBA season totals (points/rebounds/assists/steals/blocks) from the per-game
    averages every NBA source serves: total = round(per_game × games). The `nba_fantasy`
    grade scale reads these totals so NBA ranks by season-long production like every
    other sport (a 60-game heater no longer outranks a full 82 at a slightly lower rate);
    the per-game averages stay untouched for card display. Derived rather than fetched so
    the displayed averages and the graded totals can never contradict each other."""
    per_game_to_total = {"ppg": "points", "rpg": "rebounds", "apg": "assists",
                         "spg": "steals", "bpg": "blocks"}
    for s in seasons:
        if s.sport != "nba":
            continue
        if s.week is not None:   # single-game rows already carry real per-game totals,
            continue             # not per-game averages — deriving would zero them out
        games = s.stats.get("games", 0.0)
        for pg, total in per_game_to_total.items():
            s.stats[total] = float(round(s.stats.get(pg, 0.0) * games))


def gather_seasons(nfl_years: list[int], game_years: list[int] | None = None) -> list[RawSeason]:
    seasons: list[RawSeason] = []
    print(f"[nfl] fetching nflverse seasons {nfl_years[0]}–{nfl_years[-1]} …")
    seasons += nfl_nflverse.fetch_years(nfl_years)
    print(f"[nfl] {len(seasons)} player-seasons")

    print(f"[nfl] fetching nflverse defensive seasons {nfl_years[0]}–{nfl_years[-1]} …")
    seasons += nfl_nflverse_defense.fetch_years(nfl_years)
    print(f"[nfl] {len(seasons)} player-seasons (offense + defense)")

    game_years = DEFAULT_GAME_YEARS if game_years is None else game_years
    if game_years:
        print(f"[nfl] fetching nflverse single games {game_years[0]}–{game_years[-1]} …")
        games = nfl_nflverse_games.fetch_years(game_years)
        print(f"[nfl] {len(games)} player-games")
        seasons += games

    merge_nfl_bio(seasons)   # covers season + game rows alike (filters on sport=='nfl')

    # Full-league NFL history 1970–1998 (committed PFR-derived sweep; nflverse's floor is
    # 1999). Union under the live rows deduped by player_id — nflverse wins a collision
    # (it never actually collides: the two sources' year ranges are disjoint by design,
    # but the guard costs nothing and protects against a future range change).
    history = nfl_history.load_seasons()
    if history:
        by_id = {s.player_id: s for s in history}
        by_id.update({s.player_id: s for s in seasons})
        print(f"[nfl] historical sweep: {len(history)} rows (1970–1998)")
        seasons = list(by_id.values())

    backfill_nfl_headshots_by_name(seasons)   # must follow the history union (see docstring)

    # ESPN (keyless, historical) is primary; balldontlie (needs a key) then the curated
    # seed are fallbacks so the pipeline always yields real, factual NBA content.
    pool = espn_nba_pool.load_pool()  # {athlete_id: name}, refreshed via pyespn (occasional)
    if pool:
        print(f"[nba] fetching all seasons for {len(pool)} pooled stars from ESPN …")
        nba = espn_nba.fetch_by_ids(pool)
        print(f"[nba] ESPN by-id pool: {len(nba)} season averages")
    else:
        print("[nba] no id pool — falling back to seed targets via ESPN")
        nba = espn_nba.fetch_targets(NBA_LIVE_TARGETS)
    if not nba:                       # ESPN unreachable → keep the pipeline real but offline
        print("[nba] ESPN empty — using curated real-stat seed (data/nba_seed.csv)")
        nba = seed.load_nba()
    # M18: union the committed hoopR full-league sweep (every player who appeared,
    # 2002+) under the star pool. Dedupe by player_id — one entry per player-season,
    # or Keep4 candidate pools would carry the same season twice. The live ESPN row
    # wins a collision (it can be fresher for the in-progress season); hoopR fills
    # everything the leader-based pool never discovered (bench/role players).
    hoopr = hoopr_nba.load_seasons()
    if hoopr:
        by_id = {s.player_id: s for s in hoopr}
        by_id.update({s.player_id: s for s in nba})
        print(f"[nba] hoopR full-league sweep: {len(hoopr)} rows "
              f"(+{len(by_id) - len(nba)} beyond the star pool)")
        nba = list(by_id.values())
    # Full-league NBA history 1950–2001 (committed Basketball-Reference-derived sweep;
    # hoopR's floor is 2002). Deduped by player_id with the live/hoopR rows winning —
    # the ESPN star pool overlaps 1985–2001 and its rows carry guaranteed headshots.
    bref = bref_nba.load_seasons()
    if bref:
        by_id = {s.player_id: s for s in bref}
        by_id.update({s.player_id: s for s in nba})
        print(f"[nba] historical sweep: {len(bref)} rows (1950–2001)")
        nba = list(by_id.values())
    print(f"[nba] {len(nba)} player-seasons")

    # Single-game grain (M-single-game): committed hoopR box-score sweep (see
    # hoopr_nba_games's module docstring — pre-filtered to notable games only, unlike the
    # season sweep above). Game rows carry distinct `-wk`-suffixed player_ids, so a plain
    # append is safe (no dedup needed, unlike the season unions above).
    nba_games = hoopr_nba_games.load_seasons()
    if nba_games:
        print(f"[nba] hoopR single-game sweep: {len(nba_games)} player-games")
        nba += nba_games

    # MLB Stats API (keyless, verified live) is primary; the committed leader-swept pool
    # (`mlb_player_ids.json`, refreshed occasionally via providers.mlb_pool) broadens it
    # from the ~2 dozen marquee ids to hundreds of real stars. Union guarantees the
    # hardcoded current stars are always in. Seed is the offline fallback.
    mlb_ids = {**mlb_pool.load_pool(), **MLB_LIVE_TARGETS}
    print(f"[baseball] fetching {len(mlb_ids)} players from MLB Stats API "
          f"({len(mlb_pool.load_pool())} pooled + {len(MLB_LIVE_TARGETS)} marquee) …")
    baseball = mlb_stats.fetch_by_ids(mlb_ids)
    if not baseball:
        print("[baseball] MLB Stats API empty — using curated real-stat seed (data/baseball_seed.csv)")
        baseball = seed.load_baseball()
    print(f"[baseball] {len(baseball)} player-seasons")

    # Single-game grain (M-single-game): `stats=gameLog` needs one API call PER PLAYER
    # PER SEASON YEAR (no `yearByYear` equivalent), so this is bounded to the curated
    # marquee list rather than the full discovered pool — see mlb_stats_games's
    # module docstring. Reuses the same bounded `game_years` window NFL's single-game
    # pull uses.
    if game_years:
        print(f"[baseball] fetching single games for {len(MLB_LIVE_TARGETS)} marquee players "
              f"{game_years[0]}–{game_years[-1]} …")
        baseball_games = mlb_stats_games.fetch_by_ids(MLB_LIVE_TARGETS, game_years)
        print(f"[baseball] {len(baseball_games)} player-games")
        baseball += baseball_games

    # Soccer: API-Football's leaderboard sweep (providers/api_football.py, refreshed
    # occasionally via that module's own budget-limited __main__, same split as the
    # MLB/NBA pools) covers attacker output (goals/assists) for top leagues; it has no
    # source for clean sheets, so defenders/keepers always come from the hand-curated
    # seed. Tennis: still seed-only — no live source was verified working this session
    # (see providers/seed.py's module docstring).
    soccer_live = api_football.load_pool()
    soccer_seed = seed.load_soccer()
    soccer = api_football.merge_with_seed(soccer_live, soccer_seed)
    print(f"[soccer] {len(soccer_live)} live + {len(soccer_seed)} seed → {len(soccer)} player-seasons")
    # Full-squad depth 2013+ (committed Transfermarkt-derived sweep — the first source
    # ever to carry real DF/GK rows at scale; see providers/transfermarkt_soccer.py).
    # Union under seed+live deduped by player_id, existing rows winning; additionally
    # drop sweep rows that duplicate a seed row's (last name, season) under a name
    # variant ("Alisson Becker" vs the seed's "Alisson") — slug-based ids can't catch
    # those and a star must never appear twice in one pool.
    tm = transfermarkt_soccer.load_seasons()
    if tm:
        seed_last_names = {(s.name.split()[-1].lower(), s.season_year) for s in soccer_seed}
        tm = [s for s in tm
              if (s.name.split()[-1].lower(), s.season_year) not in seed_last_names]
        by_id = {s.player_id: s for s in tm}
        by_id.update({s.player_id: s for s in soccer})
        print(f"[soccer] transfermarkt full-squad sweep: {len(tm)} rows")
        soccer = list(by_id.values())
    # Broadest-but-least-curated layer: ESPN's ~38-country sweep (committed CSV — see
    # providers/espn_soccer.py). Same dedup discipline as the transfermarkt block above —
    # existing seed/live/transfermarkt rows always win a collision, both by player_id and
    # by (last name, season_year) name-variant — since this source has no per-player curation
    # beyond a minimum-appearances cameo filter.
    espn = espn_soccer.load_seasons()
    if espn:
        existing_last_names = {(s.name.split()[-1].lower(), s.season_year) for s in soccer}
        espn = [s for s in espn
                if (s.name.split()[-1].lower(), s.season_year) not in existing_last_names]
        by_id = {s.player_id: s for s in espn}
        by_id.update({s.player_id: s for s in soccer})
        print(f"[soccer] espn full-squad sweep: {len(espn)} rows")
        soccer = list(by_id.values())
    # Tennis: ATP 1968–2018 (frozen snapshot) + ATP 2019–2025 (tennis_recent, fills the
    # gap the frozen snapshot left) + WTA 1968–2025 (tennis_wta, first women's-tour
    # coverage) under the hand-curated seed, deduped by player_id with the seed winning
    # (its rows carry individually verified stats).
    atp_seasons = tennis_atp.load_seasons()
    recent_seasons = tennis_recent.load_seasons()
    wta_seasons = tennis_wta.load_seasons()
    tennis_seed = seed.load_tennis()
    tennis_by_id = {s.player_id: s for s in atp_seasons}
    tennis_by_id.update({s.player_id: s for s in recent_seasons})
    tennis_by_id.update({s.player_id: s for s in wta_seasons})
    tennis_by_id.update({s.player_id: s for s in tennis_seed})
    tennis = list(tennis_by_id.values())
    print(f"[tennis] {len(tennis)} player-seasons "
          f"({len(atp_seasons)} ATP sweep + {len(recent_seasons)} ATP recent + "
          f"{len(wta_seasons)} WTA + {len(tennis_seed)} seed)")

    all_seasons = seasons + nba + baseball + soccer + tennis
    # Bake NBA season totals BEFORE career aggregation so career rows sum real season
    # totals (a counting stat) instead of re-deriving from career-averaged rates.
    derive_nba_totals(all_seasons)
    # Career grain (M17): one aggregate row per (sport, position, player) summing every
    # real season above. Built from season-grain rows only (game rows are single
    # performances, not seasons); soccer/tennis are seed-only with ~1 season per player
    # today, so build_career_rows naturally emits none for them yet (see themes.py).
    career = build_career_rows(all_seasons)
    print(f"[career] {len(career)} career aggregates")
    return all_seasons + career


def build_rows(seasons: list[RawSeason]) -> tuple[list[PuzzleRow], list[PuzzleRow], dict]:
    """Build all puzzle rows plus the content-health report (M15) over the same pull."""
    keep4: list[PuzzleRow] = []
    keep4_built: dict[str, int] = {}
    theme_stats: list[dict] = []
    # Era-adjusted themes grade against the same baseline rows the app ships
    # (stat_baselines.json), so pipeline and client compute identical era indices.
    baselines = BaselineTable(compute_baselines(seasons))
    generated = generate.generate_themes(seasons)
    for theme in [*KEEP4_THEMES, *generated]:
        rows = assemble.build_keep4_rows(theme, seasons, baselines)
        tag = "gen " if theme.key.startswith("gen-") else "keep4 "
        print(f"  {tag}{theme.key}: {len(rows)} puzzle(s)  — {theme.title}")
        keep4 += rows
        keep4_built[theme.key] = len(rows)
        theme_stats.append(health.theme_health(theme, seasons, baselines))
    print(f"  [generator] {len(generated)} niche themes minted")

    entries = whoami_pool.all_entries(DATA_DIR)
    whoami = [assemble.build_whoami_row(e) for e in entries]
    tiers = Counter(w.content["difficulty"] for w in whoami)
    print(f"  whoami: {len(whoami)} puzzle(s) "
          f"({', '.join(f'{t}: {tiers[t]}' for t in ('easy', 'medium', 'hard'))})")
    catalog_depth = health.catalog_depth_report(seasons)
    for c in catalog_depth:
        if not c["draft_slot_viable"]:
            print(f"  [health] WARNING: {c['sport']}/{c['position']} has only "
                  f"{c['season_rows']} season rows — Draft & Spin can't deal 3 distinct candidates")
    report = health.build_report(theme_stats, keep4_built, whoami_count=len(whoami),
                                 catalog_depth=catalog_depth)
    return keep4, whoami, report


# Archival stamping starts this many days back. It must clear *every* day some device could
# still be calling "today", not just this process's own date: real offsets span UTC-12…UTC+14,
# so when the runner's clock rolls over to a new day a device in Hawaii is still on the
# previous one. At offset 1 the archival row landed on that device's live "today" and — since
# `RemotePuzzleRepository.pick` takes `rows.first(where: activeDate == today)` over a pool
# ordered by id — a stable pool row like `baseball-ace-pitchers-00` sorts ahead of that day's
# real mint (`…-daily-20260817`) and gets served as the daily, complete with a TODAY badge.
# The same collision fed `notify-daily-drop` the wrong theme name. Offset 2 is the smallest
# value that can't collide, since archival dates only ever run backwards.
_ARCHIVE_MIN_OFFSET_DAYS = 2


def assign_active_dates(rows: list[PuzzleRow], backfill_days: int) -> None:
    """Spread rows across the trailing `backfill_days` so the archive isn't empty. Deliberately
    never stamps today *or yesterday* (see `_ARCHIVE_MIN_OFFSET_DAYS`) — those dates are
    reserved for daily_puzzle.py's guaranteed-novel per-sport picks, which the client
    (RemotePuzzleRepository) trusts as an exact `active_date` match to mean "the puzzle for
    today." Every other row's active_date stays archival/informational, same as before."""
    today = dt.date.today()
    for i, row in enumerate(rows):
        offset = (i % max(1, backfill_days)) + _ARCHIVE_MIN_OFFSET_DAYS
        row.active_date = (today - dt.timedelta(days=offset)).isoformat()


def catalog_rows(seasons: list[RawSeason]) -> list[dict]:
    """Deduped player-season rows for the `player_seasons` creation catalog (snake_case).

    Single-game rows (`week` set) ARE included (as of the single-game-creation change) —
    a puzzle is a puzzle regardless of grain, and search needs a real single-game pool to
    draw from just like it needs a career pool. Career rows (M17) are included too: all
    three grains are creatable, and search needs a real pool of each to draw from."""
    by_id: dict[str, dict] = {}
    for s in seasons:
        by_id[s.player_id] = {
            "id": s.player_id, "sport": s.sport, "name": s.name,
            "team_abbr": s.team_abbr, "season_year": s.season_year,
            "position": s.position, "stats": s.stats, "headshot": s.headshot,
            "career": s.career,
            "first_year": int(s.meta["first_year"]) if s.career else None,
            "last_year": int(s.meta["last_year"]) if s.career else None,
            "league": s.meta.get("league") or None,
            # Soccer division key ("ger.2"); `league` above is only the nation, so this is
            # what a lower-division filter can enforce. None for every other sport.
            "competition": s.meta.get("competition") or None,
            "week": s.week,
            "opponent": s.opponent or None,
            "game_date": s.game_date or None,
        }
    return list(by_id.values())


# Columns an "already stored" catalog row can still be improved by — see the resend logic in
# `filter_new_catalog_rows`. Add a column here when the pipeline gains the ability to fill it
# in for rows that were written before it existed.
IMPROVABLE_COLUMNS = ("headshot", "competition")


def filter_new_catalog_rows(rows: list[dict]) -> list[dict]:
    """Drop catalog rows that are already sitting in Supabase and can never change, so a
    daily run upserts only real deltas instead of resending the entire ~130k-row catalog
    every time (the actual thing that's "pointless to scan over and over").

    Only closed-season rows are eligible to be skipped: a career aggregate's sums change
    every time its player has a new season, and the current in-progress season's stats
    change week to week — both must always be resent. A season is "closed" once
    `season_year` is strictly before the current year (this year's season may still be
    live when the pipeline runs). A single-game row (`week` set) is always "closed" the
    moment it exists — a final box score never changes after the fact, unlike a season's
    running total — so it's skip-eligible regardless of `season_year`, even for a game
    played during the current in-progress season."""
    from .upsert import fetch_existing_catalog_ids

    current_year = dt.date.today().year
    always_send = [r for r in rows
                   if r["career"] or (r["week"] is None and r["season_year"] >= current_year)]
    closed = [r for r in rows
              if not r["career"] and (r["week"] is not None or r["season_year"] < current_year)]

    by_sport: dict[str, list[dict]] = {}
    for r in closed:
        by_sport.setdefault(r["sport"], []).append(r)

    new_closed: list[dict] = []
    for sport, sport_rows in by_sport.items():
        existing_ids = fetch_existing_catalog_ids(sport)
        # "Already stored" rows are normally immutable — but a stored row missing a column
        # this run CAN fill is still improvable, and skipping it would strand the blank
        # forever. Two columns have hit this for real:
        #   headshot    — the name+era registry join (backfill_nfl_headshots_by_name) supplies
        #                 photos later; the first backfill run (2026-07-18) made 8,309 joins
        #                 and landed 0 of them in the DB for exactly this reason.
        #   competition — ~75k soccer rows were written from a CSV that predated the column,
        #                 leaving them unfilterable by nation OR division (found 2026-07-26).
        # A column is only queried for a sport whose rows actually carry it, so this costs
        # nothing for e.g. NFL, where no row has a competition to improve with.
        from .upsert import fetch_catalog_ids_missing

        improvable_ids: set[str] = set()
        for column in IMPROVABLE_COLUMNS:
            fillable = {r["id"] for r in sport_rows if r.get(column)}
            if not fillable:
                continue
            improvable_ids |= fillable & fetch_catalog_ids_missing(sport, column) & existing_ids

        improvable = [r for r in sport_rows if r["id"] in improvable_ids]
        skipped = len([r for r in sport_rows if r["id"] in existing_ids]) - len(improvable)
        new_closed.extend(r for r in sport_rows if r["id"] not in existing_ids)
        new_closed.extend(improvable)
        print(f"[catalog] {sport}: {skipped} already stored, "
              f"{len(sport_rows) - skipped - len(improvable)} new, "
              f"{len(improvable)} improvable resends")

    return always_send + new_closed


def write_catalog_fallback(seasons: list[RawSeason], per_theme: int = 200) -> None:
    """Trimmed bundled catalog so the Keep4 create flow works before the table is populated:
    the top `per_theme` graded seasons of each theme (union), in the camelCase-keyed shape
    the Swift `CatalogSeason` decodes (team_abbr/season_year stay snake_case).

    Season AND single-game grain, by design: both are creatable in the app, so both need a
    real offline pool. Career creation stays live-catalog-only (M17 decision) — the
    offline/no-network create experience already accepts a smaller pool, and career rows
    are a nice-to-have there, not a requirement. Loop below explicitly skips career themes
    when building the trim set."""
    keep_ids: set[str] = set()
    for theme in KEEP4_THEMES:
        if theme.grain == "career":   # career creation is live-catalog-only, see docstring
            continue
        pool = [s for s in seasons
                if s.sport == theme.sport and s.position in theme.positions
                and (s.week is not None) == (theme.grain == "game") and not s.career
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


def write_themes_fallback() -> None:
    """Bundle the theme catalog (`keep4_themes.json`) — the single source of truth the
    creation flow's templates decode. Pure function of KEEP4_THEMES (no season data),
    so it can run standalone via --write-themes."""
    FALLBACK_THEMES.write_text(
        json.dumps(export_themes(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"[themes] wrote {len(KEEP4_THEMES)} themes → BallIQ/Data/keep4_themes.json")


# PostgREST takes the skip-if-already-minted lookup as an `id=in.(...)` GET, so the whole id
# list lands in the URL. Ten ids (today+tomorrow) always fit; a multi-hundred-day backfill x 5
# sports does not — chunk it rather than discovering the server's URL cap mid-run.
GRID_ID_LOOKUP_CHUNK = 100
# Grid `content` is by far the heaviest payload this pipeline writes (NFL boards run to ~70 KB
# each — cells carry hundreds of answer names). upsert.py batches every table at 200 rows,
# which is right for 1 KB catalog rows and ~14 MB of JSON per request for these. Send them in
# smaller slices; the upsert stays idempotent per slice (on_conflict=id, merge-duplicates).
GRID_UPSERT_CHUNK = 25


def grid_dates(start: dt.date, days: int) -> list[str]:
    """The consecutive UTC days a `--grid` run mints, as ISO strings.

    Default is `(today, 2)` — today AND tomorrow. Tomorrow is not optional padding: pick()
    prefers the row whose active_date matches the current UTC day, so without a next-day row
    every player between 00:00 UTC and the morning cron (8pm ET onward in the US) silently
    falls back to the modulo pick over old boards — observed live 2026-07-17.

    Anything wider is the pool backfill (`--grid-days`/`--grid-start`). The pool is what
    `random_grid_puzzle` draws from, and at 13 nfl / 12 nba / 12 tennis / 3 soccer / 1 baseball
    boards "random" barely means anything; minting over a wide range deepens it with the
    generator that already exists.
    """
    if days < 1:
        raise ValueError(f"--grid-days must be at least 1, got {days}")
    return [(start + dt.timedelta(days=n)).isoformat() for n in range(days)]


def run_grid_axis_membership(sports: list[str], *, upsert: bool, dry_run: bool) -> int:
    """Evaluate every stat/position axis against the live catalog and write the matches.

    Standalone branch, same early-return posture as `--grid`: reads `player_seasons` directly and
    skips the provider gather entirely. Rewriting is safe and idempotent — the upsert is
    merge-duplicates on the full primary key, so a re-run after a threshold change adds the new
    matches. It does NOT delete rows an edited threshold no longer matches; a retuned axis gets a
    new `axis_key` (the key encodes op and value), so stale rows are unreachable rather than
    wrong, and pruning them is a cleanup, not a correctness fix.
    """
    from . import grid_axis_membership
    from .models import RawSeason
    from .upsert import fetch_player_seasons, upsert_grid_axis_membership

    load_dotenv()
    total = 0
    for sport in sports:
        seasons = [
            RawSeason(name=r["name"], team_abbr=r["team_abbr"], season_year=r["season_year"],
                      sport=r["sport"], position=r["position"], stats=r.get("stats") or {},
                      meta={"league": r.get("league") or ""})
            for r in fetch_player_seasons(sport)
        ]
        rows = grid_axis_membership.membership_rows(seasons, sport)
        axes = grid_axis_membership.axes_for(sport)
        by_axis: dict[str, int] = {}
        for row in rows:
            by_axis[row["axis_label"]] = by_axis.get(row["axis_label"], 0) + 1
        print(f"[grid-axes] {sport}: {len(axes)} axes, {len(rows)} (player, season) matches "
              f"from {len(seasons)} rows")
        for axis in axes:
            print(f"[grid-axes]   {axis.kind:<8} {axis.label:<22} {by_axis.get(axis.label, 0)}")
        if upsert:
            sent = upsert_grid_axis_membership(rows)
            print(f"[grid-axes] {sport}: upserted {sent} row(s)")
        total += len(rows)
    if dry_run and not upsert:
        print(f"[grid-axes] --dry-run: {total} row(s) not written")
    return 0


def run_grid(sports: list[str], *, upsert: bool, dry_run: bool,
             start: dt.date | None = None, days: int = 2) -> int:
    """Generate Grid puzzles for each requested sport directly from the live `player_seasons`
    catalog (not the nflverse/provider gather pipeline — Grid's data need, team x decade
    slicing, is already satisfied by that table). Standalone branch, same early-return posture
    as --write-themes: skips the heavy season pull entirely.

    Mints `days` consecutive dates from `start` (default: today and tomorrow — see
    `grid_dates`). The catalog is fetched once per sport regardless of how many dates are
    pending, so a deep backfill costs one extra generator pass per board and no extra I/O.
    """
    from . import grid
    from .models import RawSeason
    from .upsert import (fetch_existing_puzzle_ids, fetch_grid_history, fetch_player_seasons,
                         upsert_grid, upsert_grid_history)

    load_dotenv()
    start = start or dt.date.today()
    dates = grid_dates(start, days)
    # Once a (sport, date) row exists, never re-mint it: generation is deterministic per
    # (sport, date) only for a FIXED catalog, and the catalog shifts between same-day runs
    # (daily ingest + weekly refresh both re-mint) — merge-duplicates would silently swap a
    # board's content mid-day under players who already started it. Skip-if-present makes a
    # minted board immutable for its day instead. That holds for a backfill too: it may only
    # ever ADD boards to the pool, never rewrite one a player could already have opened.
    wanted = [grid.puzzle_id(s, d) for s in sports for d in dates]
    existing: set[str] = set()
    if upsert:
        for n in range(0, len(wanted), GRID_ID_LOOKUP_CHUNK):
            existing |= fetch_existing_puzzle_ids(wanted[n:n + GRID_ID_LOOKUP_CHUNK])
    # Trailing-window rejection set (grid_history): a fresh board must not repeat a recent
    # team-set x decade-set verbatim. Window is deliberately modest — long enough that a
    # repeat feels impossible, short enough to never exhaust the combo space. Anchored to the
    # earliest date being minted rather than to today, so a backfill that reaches into the past
    # still sees the history that was live around the dates it is filling.
    since = (min(start, dt.date.today())
             - dt.timedelta(days=grid.GRID_HISTORY_WINDOW_DAYS)).isoformat()
    recent_rows = fetch_grid_history(since) if upsert else []
    recent_by_sport: dict[str, set[tuple[str, str]]] = {}
    for r in recent_rows:
        recent_by_sport.setdefault(r["sport"], set()).add((r["row_teams"], r["col_decades"]))

    rows: list[dict] = []
    history: list[dict] = []
    for sport in sports:
        pending = [d for d in dates if grid.puzzle_id(sport, d) not in existing]
        # One line rather than one per date: a backfill can carry hundreds of dates, and
        # "already minted" is the expected outcome for most of them on a re-run.
        if len(pending) < len(dates):
            skipped = [d for d in dates if d not in set(pending)]
            print(f"[grid] {sport}: {len(skipped)} date(s) already minted, skipping "
                  f"({skipped[0]}..{skipped[-1]}) — a live board never shifts content mid-day")
        if not pending:
            continue
        raw = fetch_player_seasons(sport)
        seasons = [
            RawSeason(name=r["name"], team_abbr=r["team_abbr"], season_year=r["season_year"],
                     sport=r["sport"], position=r["position"], stats=r.get("stats") or {},
                     # `meta['league']` is the convention `themes.field_value` reads, so a
                     # `Filter('league', ...)` on a Grid axis resolves without special-casing.
                     meta={"league": r.get("league") or ""})
            for r in raw
        ]
        # NFL cells accept the FULL roster (every position, Immaculate-Grid-style), not just
        # the graded offensive pool — validity only; stars/viability stay graded-pool-driven.
        extra_members = None
        if sport == "nfl":
            from .providers import nfl_rosters
            extra_members = nfl_rosters.fetch_years(list(range(nfl_rosters.MIN_YEAR, _CURRENT_YEAR + 1)))
            print(f"[grid] nfl: {len(extra_members)} roster memberships widen the answer pools")
        recent = recent_by_sport.setdefault(sport, set())
        misses = 0
        for date in pending:
            puzzle = grid.generate_grid(seasons, sport=sport, date=date,
                                        extra_members=extra_members, recently_served=recent)
            if puzzle is None:
                misses += 1
                print(f"[grid] {sport} {date}: no viable grid from {len(seasons)} seasons — skipped")
                continue
            content = grid.to_content(puzzle)
            print(f"[grid] {sport} {date}: [{puzzle.archetype}] "
                  f"rows={[a.label for a in puzzle.rows]} cols={[a.label for a in puzzle.cols]} "
                  f"rarity={[c.rarity_stars for c in puzzle.cells]}")
            rows.append({
                "id": grid.puzzle_id(sport, date), "sport": sport, "format": "grid",
                "content": content, "active_date": date,
            })
            row_key, col_key = grid.combo_key(puzzle.rows, puzzle.cols)
            # Same-run dedup too: today's and tomorrow's boards must differ from each other,
            # not just from the stored trailing window.
            recent.add((row_key, col_key))
            history.append({"sport": sport, "row_teams": row_key, "col_decades": col_key,
                            "served_date": date})
        # A backfill's whole point is pool depth, so "how many of the dates I asked for
        # actually produced a board" is the number to report — a per-date miss scrolls past.
        print(f"[grid] {sport}: {len(pending) - misses}/{len(pending)} board(s) built"
              + (f", {misses} with no viable grid" if misses else ""))

    if dry_run or not upsert:
        print(f"\n(grid: {len(rows)} puzzle(s) built" + ("" if upsert else ", pass --upsert to write") + ")")
        return 0

    sent = 0
    for n in range(0, len(rows), GRID_UPSERT_CHUNK):
        sent += upsert_grid(rows[n:n + GRID_UPSERT_CHUNK])
    print(f"[upsert] sent {sent} grid puzzle rows to Supabase")
    if history:
        hist_sent = upsert_grid_history(history)
        print(f"[upsert] recorded {hist_sent} grid history row(s)")
    return 0


def run_teams(*, do_teams: bool, do_leagues: bool, upsert: bool, dry_run: bool) -> int:
    """Build + (optionally) upsert `teams`/`leagues` club/league identity rows. Standalone
    branch, same early-return posture as --grid: skips the season-gather pull entirely —
    this data need (club logos/colors/full names) is independent of it."""
    from . import teams as teams_module
    from .upsert import upsert_leagues, upsert_teams

    load_dotenv()
    team_rows: list[dict] = []
    league_rows: list[dict] = []
    if do_teams:
        team_rows = teams_module.build_teams()
        print(f"[teams] built {len(team_rows)} team row(s)")
    if do_leagues:
        league_rows = teams_module.build_leagues()
        print(f"[leagues] built {len(league_rows)} league row(s)")

    if dry_run or not upsert:
        if not dry_run:
            print("\n(teams/leagues: pass --upsert to write)")
        return 0

    if team_rows:
        sent = upsert_teams(team_rows)
        print(f"[upsert] sent {sent} team rows to Supabase")
    if league_rows:
        sent = upsert_leagues(league_rows)
        print(f"[upsert] sent {sent} league rows to Supabase")
    return 0


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
    # Subset for the same reason keep4 is: the pool is 762 puzzles (~630 KB) since the
    # catalog-generated subjects landed, and the bundle only has to cover an offline session.
    whoami_subset = whoami_pool.bundle_subset(whoami)
    FALLBACK_WHOAMI.write_text(
        json.dumps([r.content for r in whoami_subset], indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[fallback] wrote {len(keep4_subset)} keep4 + {len(whoami_subset)} whoami "
          f"(of {len(whoami)}) → BallIQ/Data/")


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
    ap.add_argument("--game-years", type=int, nargs="+", default=DEFAULT_GAME_YEARS,
                    help="single-game grain years (weekly files are heavy; bounded by default)")
    ap.add_argument("--upsert", action="store_true", help="upsert rows into Supabase")
    ap.add_argument("--catalog", action="store_true",
                    help="also upsert player_seasons (creation catalog) + write its fallback")
    ap.add_argument("--write-fallback", action="store_true", help="rewrite bundled offline JSON")
    ap.add_argument("--write-themes", action="store_true",
                    help="rewrite BallIQ/Data/keep4_themes.json only (no data pull)")
    ap.add_argument("--dry-run", action="store_true", help="build + validate + print, no writes")
    ap.add_argument("--grid", nargs="+", choices=["nfl", "nba", "baseball", "soccer", "tennis"],
                    help="generate Grid puzzles for the given sport(s) from the live "
                         "player_seasons catalog (standalone — skips the season gather pull)")
    ap.add_argument("--grid-days", type=int, default=2, metavar="N",
                    help="how many consecutive days of Grid boards to mint (default 2: today "
                         "and tomorrow). Raise it to backfill a deep pool — the pool is what "
                         "the Grid's 'new random board' draws from")
    ap.add_argument("--grid-start", type=dt.date.fromisoformat, metavar="YYYY-MM-DD",
                    help="first day of the --grid-days window (default today, UTC). Backfilling "
                         "into the past deepens the pool without pre-committing future dailies")
    ap.add_argument("--grid-axis-membership", nargs="+", metavar="SPORT",
                    choices=["nfl", "nba", "baseball", "soccer", "tennis"],
                    help="materialise which (player, season) pairs satisfy each stat/position "
                         "axis into `grid_axis_membership` — the input the CLIENT needs to "
                         "generate mixed practice boards (standalone; reads the live catalog)")
    ap.add_argument("--teams", action="store_true",
                    help="build (and, with --upsert, write) `teams` club identity rows "
                         "(logos rehosted to Storage, colors, full names) — standalone, "
                         "skips the season gather pull")
    ap.add_argument("--leagues", action="store_true",
                    help="build (and, with --upsert, write) `leagues` identity rows — "
                         "standalone, skips the season gather pull; combine with --teams "
                         "to do both in one run")
    ap.add_argument("--evict-current-season", action="store_true",
                    help="delete current/previous-year cache entries (and the live ESPN NBA "
                         "stat files) before fetching, so in-season data is refetched fresh — "
                         "the weekly refresh workflow's flag; historical caches are untouched")
    args = ap.parse_args()

    if args.evict_current_season:
        from .providers.http import evict_current_season
        removed = evict_current_season(dt.date.today().year)
        print(f"[cache] evicted {removed} current-season cache file(s)")

    if args.write_themes and not (args.upsert or args.write_fallback or args.dry_run):
        write_themes_fallback()      # standalone: themes are static, skip the data pull
        return 0

    if args.grid:
        return run_grid(args.grid, upsert=args.upsert, dry_run=args.dry_run,
                        start=args.grid_start, days=args.grid_days)

    if args.grid_axis_membership:
        return run_grid_axis_membership(args.grid_axis_membership,
                                        upsert=args.upsert, dry_run=args.dry_run)

    if args.teams or args.leagues:
        return run_teams(do_teams=args.teams, do_leagues=args.leagues,
                         upsert=args.upsert, dry_run=args.dry_run)

    load_dotenv()
    seasons = gather_seasons(args.nfl_years, args.game_years)
    keep4, whoami, health_report = build_rows(seasons)
    all_rows = keep4 + whoami

    # Written on every run, --dry-run included — the durable version of the pool
    # stats above (see docs/ANALYTICS.md for how to read it).
    health.write_report(health_report, CONTENT_HEALTH)
    print(f"[health] wrote {len(health_report['themes'])} theme stats → {CONTENT_HEALTH.name}")

    for row in all_rows:
        validate(row)
    print(f"[validate] {len(all_rows)} rows OK")

    assign_active_dates(all_rows, args.backfill)
    print_summary(keep4, whoami)

    if args.write_fallback:
        write_fallback(keep4, whoami)
        write_catalog_fallback(seasons)
        write_baselines_fallback(seasons)
        write_themes_fallback()

    if args.upsert:
        from .upsert import upsert, upsert_catalog
        sent = upsert(all_rows)
        print(f"[upsert] sent {sent} puzzle rows to Supabase")
        if args.catalog:
            rows = filter_new_catalog_rows(catalog_rows(seasons))
            print(f"[upsert] sending {len(rows)} new/changed player_seasons …")
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
