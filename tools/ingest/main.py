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
    espn_nba,
    espn_nba_pool,
    mlb_pool,
    mlb_stats,
    nba_balldontlie,
    nfl_nflverse,
    nfl_nflverse_games,
    nfl_players,
    seed,
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
    print(f"[nba] {len(nba)} player-seasons")

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

    # Soccer and tennis: seed-only for now — no live club-stats/historical source
    # was verified working this session (see providers/seed.py's module docstring).
    soccer = seed.load_soccer()
    print(f"[soccer] {len(soccer)} player-seasons (seed only)")
    tennis = seed.load_tennis()
    print(f"[tennis] {len(tennis)} player-seasons (seed only)")

    all_seasons = seasons + nba + baseball + soccer + tennis
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
    report = health.build_report(theme_stats, keep4_built, whoami_count=len(whoami))
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

    Excludes single-game rows (`week` set) — the Create flow's on-device grading isn't
    built for single games (an explicit non-goal). Career rows (M17) ARE included: the
    4 career themes are creatable, and search needs a real career pool to draw from."""
    by_id: dict[str, dict] = {}
    for s in seasons:
        if s.week is not None:
            continue
        by_id[s.player_id] = {
            "id": s.player_id, "sport": s.sport, "name": s.name,
            "team_abbr": s.team_abbr, "season_year": s.season_year,
            "position": s.position, "stats": s.stats, "headshot": s.headshot,
            "career": s.career,
            "first_year": int(s.meta["first_year"]) if s.career else None,
            "last_year": int(s.meta["last_year"]) if s.career else None,
        }
    return list(by_id.values())


def write_catalog_fallback(seasons: list[RawSeason], per_theme: int = 40) -> None:
    """Trimmed bundled catalog so the Keep4 create flow works before the table is populated:
    the top `per_theme` graded seasons of each theme (union), in the camelCase-keyed shape
    the Swift `CatalogSeason` decodes (team_abbr/season_year stay snake_case).

    Season-grain only, by design (M17 decision): career creation is live-catalog-only —
    the offline/no-network create experience already accepts a smaller pool, and career
    rows are a nice-to-have there, not a requirement. Loop below explicitly skips any
    non-season theme (including the 4 career ones) when building the trim set."""
    keep_ids: set[str] = set()
    for theme in KEEP4_THEMES:
        if theme.grain != "season":   # catalog_rows() only has season rows; skip the pool too
            continue
        pool = [s for s in seasons
                if s.sport == theme.sport and s.position in theme.positions
                and s.week is None and not s.career
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
    args = ap.parse_args()

    if args.write_themes and not (args.upsert or args.write_fallback or args.dry_run):
        write_themes_fallback()      # standalone: themes are static, skip the data pull
        return 0

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
            rows = catalog_rows(seasons)
            print(f"[upsert] sending {len(rows)} player_seasons …")
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
