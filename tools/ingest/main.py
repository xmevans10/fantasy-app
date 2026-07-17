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

from . import assemble, generate, health
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

    entries = assemble.load_whoami_entries(DATA_DIR / "whoami_facts.json")
    whoami = [assemble.build_whoami_row(e) for e in entries]
    print(f"  whoami: {len(whoami)} puzzle(s)")
    catalog_depth = health.catalog_depth_report(seasons)
    for c in catalog_depth:
        if not c["draft_slot_viable"]:
            print(f"  [health] WARNING: {c['sport']}/{c['position']} has only "
                  f"{c['season_rows']} season rows — Draft & Spin can't deal 3 distinct candidates")
    report = health.build_report(theme_stats, keep4_built, whoami_count=len(whoami),
                                 catalog_depth=catalog_depth)
    return keep4, whoami, report


def assign_active_dates(rows: list[PuzzleRow], backfill_days: int) -> None:
    """Spread rows across the trailing `backfill_days` so the archive isn't empty. Deliberately
    never stamps *today* (offset starts at 1, not 0) — today's exact date is reserved for
    daily_puzzle.py's single guaranteed-novel pick, which the client (RemotePuzzleRepository)
    trusts as an exact `active_date` match to mean "the puzzle for today." Every other row's
    active_date stays archival/informational, same as before."""
    today = dt.date.today()
    for i, row in enumerate(rows):
        offset = (i % max(1, backfill_days)) + 1
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
            "week": s.week,
            "opponent": s.opponent or None,
            "game_date": s.game_date or None,
        }
    return list(by_id.values())


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
        skipped = [r for r in sport_rows if r["id"] in existing_ids]
        new_closed.extend(r for r in sport_rows if r["id"] not in existing_ids)
        print(f"[catalog] {sport}: {len(skipped)} already stored, {len(sport_rows) - len(skipped)} new")

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


def run_grid(sports: list[str], *, upsert: bool, dry_run: bool) -> int:
    """Generate today's Grid puzzle for each requested sport directly from the live
    `player_seasons` catalog (not the nflverse/provider gather pipeline — Grid's data need,
    team x decade slicing, is already satisfied by that table). Standalone branch, same
    early-return posture as --write-themes: skips the heavy season pull entirely."""
    from . import grid
    from .models import RawSeason
    from .upsert import fetch_player_seasons

    load_dotenv()
    today = dt.date.today().isoformat()
    rows: list[dict] = []
    for sport in sports:
        raw = fetch_player_seasons(sport)
        seasons = [
            RawSeason(name=r["name"], team_abbr=r["team_abbr"], season_year=r["season_year"],
                     sport=r["sport"], position=r["position"], stats=r.get("stats") or {})
            for r in raw
        ]
        # NFL cells accept the FULL roster (every position, Immaculate-Grid-style), not just
        # the graded offensive pool — validity only; stars/viability stay graded-pool-driven.
        extra_members = None
        if sport == "nfl":
            from .providers import nfl_rosters
            extra_members = nfl_rosters.fetch_years(list(range(nfl_rosters.MIN_YEAR, _CURRENT_YEAR + 1)))
            print(f"[grid] nfl: {len(extra_members)} roster memberships widen the answer pools")
        puzzle = grid.generate_grid(seasons, sport=sport, date=today, extra_members=extra_members)
        if puzzle is None:
            print(f"[grid] {sport}: no viable grid from {len(seasons)} seasons — skipped")
            continue
        content = grid.to_content(puzzle)
        print(f"[grid] {sport}: rows={puzzle.row_teams} cols={puzzle.col_decades} "
              f"rarity={[c.rarity_stars for c in puzzle.cells]}")
        rows.append({
            "id": grid.puzzle_id(sport, today), "sport": sport, "format": "grid",
            "content": content, "active_date": today,
        })

    if dry_run or not upsert:
        print(f"\n(grid: {len(rows)} puzzle(s) built" + ("" if upsert else ", pass --upsert to write") + ")")
        return 0

    from .upsert import upsert_grid
    sent = upsert_grid(rows)
    print(f"[upsert] sent {sent} grid puzzle rows to Supabase")
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
                    help="generate today's Grid puzzle for the given sport(s) from the live "
                         "player_seasons catalog (standalone — skips the season gather pull)")
    args = ap.parse_args()

    if args.write_themes and not (args.upsert or args.write_fallback or args.dry_run):
        write_themes_fallback()      # standalone: themes are static, skip the data pull
        return 0

    if args.grid:
        return run_grid(args.grid, upsert=args.upsert, dry_run=args.dry_run)

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
