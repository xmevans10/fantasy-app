"""Soccer per-match box-score sweep — ESPN's public `site.api.espn.com` JSON API
(keyless, undocumented but stable; the same API family `espn_nba.py` already trusts for
NBA, verified live 2026-07-12). Covers the first division of **~38 countries**, not just
the Big-5 `transfermarkt_soccer.py` already handles — real coverage confirmed live in
Brazil, Argentina, MLS, Mexico, Colombia, Portugal, Netherlands, and more, each with
genuine per-player goalkeeper box score (saves, shots faced, goals conceded), not just a
scoreline-derived clean-sheet count.

Why this exists alongside `transfermarkt_soccer.py`:
- That provider already gives full-squad goals/assists/clean_sheets for 14 European
  leagues, 2012+ (clean_sheets there is *derived* from the match scoreline).
- This one adds (1) ~35 more countries' top flights (South America, MLS, Mexico, Japan,
  China, India, Saudi Arabia, South Africa, Australia, plus more of Europe), and (2) for
  every league here, real per-player `saves`/`shots_faced` — kept in the CSV for a future
  scoring-formula fast-follow, NOT fed into `grade.py` (see the note below).
- v1 output keeps the SAME stat shape as `transfermarkt_soccer.py`/`soccer_seed.csv`
  (`appearances`, `goals`, `assists`, `clean_sheets`) so it merges under the existing
  soccer scoring formula with zero `grade.py`/`GradeFormula.swift`/`ScoringRule.swift`
  changes — adding a new *scored* stat category is a sacred-invariant change per
  AGENTS.md §4/§11 and `docs/BALLIQ_SPEC.md` §4 (needs those three files updated in
  lockstep with locked-value tests), and is a product decision, not a data-pipeline one.

No `soccerdata` (or any third-party) dependency: the endpoints are simple enough
(`.../soccer/{league}/scoreboard?dates=...` and `.../soccer/{league}/summary?event=...`)
that a stdlib client following this pipeline's existing `providers.http.fetch_json`
caching convention is a smaller footprint than a pandas-based package limited to a
5-league hardcoded dict — see `AGENTS.md` §11 rung 2/6 (already-solved beats a new dep).

Position quirk (verified live): ESPN's per-match `position` field is the KICKOFF
on-field role ("Center Right Defender", "Right Back", ...) and is literally the string
"Substitute" for anyone who didn't start — useless per-match for bench players. Resolved
once per player, globally, from the mode of their non-"Substitute" labels across every
match collected (`_resolve_positions`), then bucketed to GK/DF/MF/FW by keyword
(`_bucket_position`).

`goals_conceded` in a match's per-player stats is a TEAM stat (identical for every player
on that side, that match) — used directly for `clean_sheets` (== 0), no separate
scoreline lookup needed (unlike `transfermarkt_soccer.py`, which derives it from a
separate games.csv).

Season floor varies enormously by league (verified live via ESPN's own clamp-to-earliest
behavior: request a date before any data exists and read back what season it resolves
to) — MLS goes back to 1997, most of Europe/Argentina/Mexico to ~2000-01, Brazil/Japan/
South Africa to ~2006, Saudi Arabia only to 2022. `_LEAGUE_FLOORS` below is that
per-league empirical floor; `refresh()` treats a season with zero discovered matches as
"not covered yet" and skips it rather than erroring, so an over-conservative floor guess
degrades gracefully instead of crashing.

Discovery is 3-tier per (league, season): one call reads the season's match-day
`calendar` from a `scoreboard` response, one `scoreboard?dates=<day>` call per match day
lists that day's event ids (~35-40 calls), then one `summary?event=<id>` call per match
returns both rosters' full per-player box score. A handful of leagues × several seasons
is a reasonable single run; **all ~38 leagues × their full multi-decade depth is a
many-hour one-time backfill** — validate on a small scope first (see `main()`'s
`--leagues`/`--from`/`--to`), then background the full historical sweep.

Run:  python -m tools.ingest.providers.espn_soccer --leagues eng.1 bra.1 usa.1 \\
        --from 2023 --to 2025
      (season *end* years throughout, matching the rest of the pipeline's convention —
      `--from 2023` means the 2022-23 / 2023 season, whichever that league uses)
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import time
from pathlib import Path
from typing import Iterable

from ..models import RawSeason
from .http import fetch_json
from .transfermarkt_soccer import _short_code
from .wikimedia import headshot as wiki_headshot

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "soccer_espn_seasons.csv"

_API = "http://site.api.espn.com/apis/site/v2/sports/soccer/{league}/{endpoint}"

# A courtesy pause between UNCACHED live calls — ESPN is keyless and generous (same
# precedent as espn_nba.py's _RATE_DELAY), but this sweep makes vastly more calls per
# run, so the pause matters more here.
_RATE_DELAY = 0.15

MIN_APPEARANCES = 5   # a real squad season, not a cameo

CSV_FIELDS = ["name", "team_abbr", "season_year", "position",
              "appearances", "goals", "assists", "clean_sheets", "headshot", "league"]

# ESPN league slug -> country/league label (for logging only). Every entry here was
# live-verified 2026-07-12 to return real teams and, for a spot-checked sample across
# every continent, real per-match goalkeeper box-score stats.
_LEAGUES: dict[str, str] = {
    "eng.1": "England", "esp.1": "Spain", "ger.1": "Germany", "ita.1": "Italy",
    "fra.1": "France", "por.1": "Portugal", "ned.1": "Netherlands", "bel.1": "Belgium",
    "sco.1": "Scotland", "tur.1": "Turkey", "rus.1": "Russia", "gre.1": "Greece",
    "den.1": "Denmark", "sui.1": "Switzerland", "aut.1": "Austria", "swe.1": "Sweden",
    "nor.1": "Norway", "irl.1": "Ireland", "isr.1": "Israel", "rou.1": "Romania",
    "bra.1": "Brazil", "arg.1": "Argentina", "usa.1": "USA (MLS)", "mex.1": "Mexico",
    "chi.1": "Chile", "col.1": "Colombia", "per.1": "Peru", "uru.1": "Uruguay",
    "ecu.1": "Ecuador", "ven.1": "Venezuela", "bol.1": "Bolivia", "par.1": "Paraguay",
    "jpn.1": "Japan", "chn.1": "China", "ind.1": "India", "ksa.1": "Saudi Arabia",
    "rsa.1": "South Africa", "aus.1": "Australia",
}

# Empirical season floor (the season END year ESPN's own clamp resolves an
# out-of-range request to) — probed live 2026-07-12 via `scoreboard?dates=<early date>`.
# Conservative where the probe was ambiguous (a few leagues' scoreboard fell through to
# "current season" on an extremely early date rather than clamping to their true floor —
# re-probed at safer intervals; see the module docstring). `refresh()` skips a season
# with zero discovered matches, so an over-conservative guess here just means slightly
# less depth, never a crash.
_LEAGUE_FLOORS: dict[str, int] = {
    "eng.1": 2002, "esp.1": 2001, "ger.1": 2001, "ita.1": 2001, "fra.1": 2001,
    "por.1": 2001, "ned.1": 2001, "bel.1": 2007, "sco.1": 2002, "tur.1": 2007,
    "rus.1": 2007, "gre.1": 2007, "den.1": 2007, "sui.1": 2016, "aut.1": 2007,
    "swe.1": 2009, "nor.1": 2009, "irl.1": 2010, "isr.1": 2017, "rou.1": 2017,
    "bra.1": 2007, "arg.1": 2001, "usa.1": 1998, "mex.1": 2001, "chi.1": 2006,
    "col.1": 2006, "per.1": 2006, "uru.1": 2006, "ecu.1": 2006, "ven.1": 2006,
    "bol.1": 2006, "par.1": 2006, "jpn.1": 2007, "chn.1": 2017, "ind.1": 2016,
    "ksa.1": 2023, "rsa.1": 2007, "aus.1": 2006,
}

_POSITION_KEYWORDS = (
    ("goalkeeper", "GK"), ("keeper", "GK"),
    ("back", "DF"), ("defen", "DF"),
    ("midfield", "MF"),
    ("forward", "FW"), ("striker", "FW"), ("wing", "FW"),
)


def _bucket_position(label: str) -> str:
    """ESPN's free-text on-field role -> the sport's GK/DF/MF/FW convention. Falls back
    to MF (no confident signal) for the rare player who is *only* ever "Substitute"."""
    low = label.lower()
    for keyword, bucket in _POSITION_KEYWORDS:
        if keyword in low:
            return bucket
    return "MF"


def _resolve_positions(position_labels: dict[str, list[str]]) -> dict[str, str]:
    """Per player, the most common non-"Substitute" position label they were ever
    given (across every match collected for them), bucketed. Pure + testable."""
    resolved: dict[str, str] = {}
    for name, labels in position_labels.items():
        real = [label for label in labels if label and label.lower() != "substitute"]
        pool = real or labels
        common = collections.Counter(pool).most_common(1)[0][0] if pool else ""
        resolved[name] = _bucket_position(common)
    return resolved


def _aggregate_rows(rows: Iterable[dict]) -> tuple[
        dict[tuple[str, str, int, str], dict], dict[str, list[str]]]:
    """Per-match, per-player box-score rows -> (name, team, season_end_year, league)
    season totals, plus each player's position-label history (kept separate so position
    can be resolved globally before the caller filters by `MIN_APPEARANCES`).

    The `league` slug is included in the key (not just carried as a value) so two
    different leagues' rows for the same name/team/season never get summed into one
    total — a same-name player on a same-named team in two different countries'
    competitions should never merge.

    Expected row shape: {"player": str, "team": str, "season_end_year": int,
    "position": str, "appearances": float, "total_goals": float,
    "goal_assists": float, "goals_conceded": float, "league": str}. Matches the plain-dict
    shape this module's own `_lineup_rows` builds from ESPN's JSON — kept dict-based (not
    a DataFrame) so this stays unit-testable with hand-built fixtures, no pandas."""
    totals: dict[tuple[str, str, int, str], dict] = collections.defaultdict(
        lambda: {"appearances": 0, "goals": 0, "assists": 0, "clean_sheets": 0})
    labels: dict[str, list[str]] = collections.defaultdict(list)
    for row in rows:
        name = row["player"]
        labels[name].append(row.get("position") or "")
        if (row.get("appearances") or 0) <= 0:
            continue
        key = (name, row["team"], row["season_end_year"], row.get("league") or "")
        t = totals[key]
        t["appearances"] += 1
        t["goals"] += int(row.get("total_goals") or 0)
        t["assists"] += int(row.get("goal_assists") or 0)
        if (row.get("goals_conceded") or 0) == 0:
            t["clean_sheets"] += 1
    return totals, labels


# ---------------------------------------------------------------------------
# network refresh path (heavy — never called from load_seasons/runtime)

def _get(endpoint: str, league: str, *, cache_key: str, ttl_hours: float) -> dict:
    url = _API.format(league=league, endpoint=endpoint)
    return fetch_json(url, cache_key=cache_key, ttl_hours=ttl_hours)


def _season_match_days(league: str, season_end_year: int) -> list[str]:
    """The season's real match days (YYYYMMDD), from the `calendar` array on a
    scoreboard response seeded at the season's nominal start (July 1 of the start
    year — matches ESPN's own season-labeling convention)."""
    start_year = season_end_year - 1
    seed_date = f"{start_year}0701"
    data = _get(f"scoreboard?dates={seed_date}", league,
                cache_key=f"espn_soccer_{league}_{season_end_year}_calendar.json",
                ttl_hours=24 * 180)
    calendar = data.get("leagues", [{}])[0].get("calendar", [])
    return sorted({d[:10].replace("-", "") for d in calendar if d})


def _match_ids_for_day(league: str, day: str, *, is_current_season: bool) -> list[str]:
    ttl = 6.0 if is_current_season else 24 * 365 * 5   # a finished day never changes
    data = _get(f"scoreboard?dates={day}", league,
                cache_key=f"espn_soccer_{league}_{day}_events.json", ttl_hours=ttl)
    return [e["id"] for e in data.get("events", [])]


def _lineup_rows(league: str, event_id: str, season_end_year: int) -> list[dict]:
    """One match's both-rosters box score -> flat per-player dict rows (see
    `_aggregate_rows`'s docstring for the shape)."""
    data = _get(f"summary?event={event_id}", league,
                cache_key=f"espn_soccer_{league}_match_{event_id}.json",
                ttl_hours=24 * 365 * 5)   # a played match's boxscore is immutable
    rows: list[dict] = []
    for roster in data.get("rosters", []):
        team = roster.get("team", {}).get("displayName") or ""
        if not team:
            continue
        for p in roster.get("roster", []):
            stats = {s["name"]: s.get("value") for s in p.get("stats", [])}
            rows.append({
                "player": (p.get("athlete") or {}).get("displayName") or "",
                "team": team,
                "season_end_year": season_end_year,
                "position": (p.get("position") or {}).get("name") or "",
                "appearances": stats.get("appearances"),
                "total_goals": stats.get("totalGoals"),
                "goal_assists": stats.get("goalAssists"),
                "goals_conceded": stats.get("goalsConceded"),
                "league": league,
            })
    return rows


def refresh(leagues: list[str] | None = None,
            season_from: int | None = None, season_to: int | None = None,
            out_path: Path | None = None) -> None:
    """Discover + aggregate every (league, season) in range, resolve headshots, write
    to `out_path` (default: the committed CSV). Safe to re-run/resume: each network call
    is cached on disk keyed by (league, day/event), so a re-run after a partial/
    interrupted sweep only fetches what it doesn't already have. `out_path` exists so a
    CI matrix job (one leg per league — see `.github/workflows/espn-soccer-backfill.yml`)
    can write its own partition instead of every parallel leg colliding on one file;
    `merge_csvs` below recombines those partitions into the single committed CSV."""
    leagues = leagues or list(_LEAGUES)
    season_to = season_to or dt.date.today().year + (1 if dt.date.today().month >= 7 else 0)

    all_rows: list[dict] = []
    for league in leagues:
        floor = _LEAGUE_FLOORS.get(league, season_from or 2015)
        lo = max(season_from or floor, floor)
        current_season_end = dt.date.today().year + (1 if dt.date.today().month >= 7 else 0)
        for season_end in range(lo, season_to + 1):
            try:
                days = _season_match_days(league, season_end)
            except Exception as err:  # noqa: BLE001 — a bad/uncovered season shouldn't sink the sweep
                print(f"[espn-soccer] {league} {season_end}: calendar fetch failed ({err})")
                continue
            if not days:
                print(f"[espn-soccer] {league} {season_end}: 0 match days — not covered, skipping")
                continue
            is_current = season_end >= current_season_end
            event_ids: list[str] = []
            for day in days:
                try:
                    event_ids.extend(_match_ids_for_day(league, day, is_current_season=is_current))
                except Exception as err:  # noqa: BLE001 — one flaky day shouldn't sink the season
                    print(f"[espn-soccer] {league} {season_end} day {day}: skipped ({err})")
                    continue
                time.sleep(_RATE_DELAY)
            if not event_ids:
                print(f"[espn-soccer] {league} {season_end}: 0 matches — skipping")
                continue
            season_rows = 0
            for event_id in event_ids:
                try:
                    rows = _lineup_rows(league, event_id, season_end)
                except Exception as err:  # noqa: BLE001 — one bad match shouldn't sink the season
                    print(f"[espn-soccer] {league} {season_end} match {event_id}: skipped ({err})")
                    continue
                all_rows.extend(rows)
                season_rows += len(rows)
                time.sleep(_RATE_DELAY)
            print(f"[espn-soccer] {league} {season_end}: {len(event_ids)} matches, "
                  f"{season_rows} player-match rows")

    print(f"[espn-soccer] aggregating {len(all_rows)} player-match rows …")
    totals, labels = _aggregate_rows(all_rows)
    positions = _resolve_positions(labels)

    kept: list[dict] = []
    dropped_cameo = 0
    players_needing_headshot: set[str] = set()
    for (name, team, season_end_year, league), stats in totals.items():
        if stats["appearances"] < MIN_APPEARANCES:
            dropped_cameo += 1
            continue
        players_needing_headshot.add(name)
        kept.append({
            "name": name, "team_abbr": _short_code(team), "season_year": season_end_year,
            "position": positions.get(name, "MF"),
            "appearances": stats["appearances"], "goals": stats["goals"],
            "assists": stats["assists"], "clean_sheets": stats["clean_sheets"],
            "league": _LEAGUES.get(league, league),
        })
    print(f"[espn-soccer] {len(kept)} qualifying player-seasons "
          f"({dropped_cameo} dropped as cameos)")

    print(f"[espn-soccer] resolving Wikipedia headshots for {len(players_needing_headshot)} players …")
    headshots = {name: wiki_headshot(name, context="soccer")
                 for name in sorted(players_needing_headshot)}
    matched = sum(1 for v in headshots.values() if v)
    print(f"[espn-soccer] {matched}/{len(players_needing_headshot)} players matched a real soccer photo")

    final = []
    for row in kept:
        if shot := headshots.get(row["name"], ""):
            row["headshot"] = shot
            final.append(row)
    final.sort(key=lambda r: (r["name"], r["season_year"], r["team_abbr"]))

    dest = out_path or CSV_PATH
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(final)
    print(f"[espn-soccer] wrote {len(final)} player-seasons (M16 photo gate: "
          f"{len(kept) - len(final)} dropped, no confident photo) → {dest}")


def merge_csvs(inputs: list[Path], out_path: Path) -> None:
    """Recombines the per-league CSV partitions a CI matrix job's legs each wrote (via
    `refresh(..., out_path=...)`) into the one committed CSV — the counterpart to that
    partitioning. Every input already has this module's own headshot/cameo gates applied
    (each leg ran a real `refresh()`), so this is a plain concatenate + re-sort, no
    re-filtering."""
    rows: list[dict] = []
    for path in inputs:
        with path.open(encoding="utf-8") as f:
            rows.extend(csv.DictReader(f))
    rows.sort(key=lambda r: (r["name"], int(r["season_year"]), r["team_abbr"]))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"[espn-soccer] merged {len(inputs)} league partitions, {len(rows)} rows → {out_path}")


# ---------------------------------------------------------------------------
# runtime path (stdlib-only)

def load_seasons() -> list[RawSeason]:
    """ESPN-sourced full-squad soccer player-seasons from the committed CSV (empty list
    until the refresh has been run). Identical column layout and stat keys to
    `transfermarkt_soccer.load_seasons`/`seed.load_soccer`, so all three merge cleanly."""
    if not CSV_PATH.exists():
        return []
    out: list[RawSeason] = []
    with CSV_PATH.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out.append(RawSeason(
                name=row["name"],
                team_abbr=row["team_abbr"],
                season_year=int(row["season_year"]),
                sport="soccer",
                position=row["position"],
                stats={
                    "appearances": float(row["appearances"]),
                    "goals": float(row["goals"]),
                    "assists": float(row["assists"]),
                    "clean_sheets": float(row["clean_sheets"]),
                },
                source="espn",
                headshot=row["headshot"],
                meta={"league": row["league"]} if row.get("league") else {},
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Refresh the committed ESPN full-squad soccer sweep "
                    "(~38 countries' first divisions)")
    ap.add_argument("--leagues", nargs="+", choices=sorted(_LEAGUES),
                    help="ESPN league slugs to sweep (default: all)")
    ap.add_argument("--from", dest="season_from", type=int, default=None,
                    help="earliest season END year (default: each league's empirical floor)")
    ap.add_argument("--to", dest="season_to", type=int, default=None,
                    help="latest season END year (default: current)")
    ap.add_argument("--out", type=Path, default=None,
                    help="write to this CSV instead of the committed data file "
                         "(a CI matrix leg's own partition — see merge-dir below)")
    ap.add_argument("--merge-dir", type=Path, default=None,
                    help="skip the live sweep; merge every *.csv in this directory "
                         "(matrix legs' --out partitions) into --out (or the committed "
                         "CSV if --out is omitted)")
    args = ap.parse_args()
    if args.merge_dir:
        merge_csvs(sorted(args.merge_dir.glob("*.csv")), args.out or CSV_PATH)
        return 0
    refresh(leagues=args.leagues, season_from=args.season_from, season_to=args.season_to,
            out_path=args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
