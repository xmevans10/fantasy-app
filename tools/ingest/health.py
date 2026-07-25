"""Content-health artifact (M15).

The per-theme pool/coverage stats the pipeline always computed internally used to
exist only as ``--dry-run`` stdout. This module turns them into a durable
``content_health.json`` written on every run, answering: how deep is each theme's
candidate pool, how much did the min-stat floors and niche filters exclude, and do
era-adjusted themes have baseline coverage for every season they graded.
"""
from __future__ import annotations

import collections
import datetime as dt
import json
from pathlib import Path

from .assemble import KEEP_COUNT, grade_pool
from .grade import FANTASY_TOTAL_STAT, BaselineTable
from .models import RawSeason
from .themes import Theme

# Mirrors `DraftSpinConstraint.lineupSlots(for:)` in BallIQ/Models/DraftSpin.swift — the
# (sport, position) pairs a Draft & Spin lineup slot actually filters by. NBA/tennis slots
# are unslotted (`nil` position, draws from the whole sport pool) so they're not listed here.
# Kept as a hand-maintained mirror rather than a shared source file since one side is Swift
# and the other Python; if `lineupSlots` changes, update this set in the same change.
DRAFT_SPIN_SLOT_POSITIONS: frozenset[tuple[str, str]] = frozenset({
    ("nfl", "QB"), ("nfl", "RB"), ("nfl", "WR"), ("nfl", "TE"),
    ("baseball", "H"), ("baseball", "P"),
    ("soccer", "GK"), ("soccer", "DF"), ("soccer", "FW"), ("soccer", "MF"),
})

# Below this many season-grain rows, a draft slot can't reliably offer 3 *distinct* daily
# candidates (Draft & Spin draws 3 without replacement) — this is the exact bug class caught
# twice in the M5 Phase D session (soccer GK/DF slots empty, then DF stuck at 1 candidate).
MIN_ROWS_FOR_DRAFT_SLOT = 3

# Soccer's Draft & Spin formation is 8 slots (GK/DF/DF/MF/MF/MF/FW/FW) — a single
# (team_abbr, season_year, league) combo below this many rows can't field even that
# formation from one real squad, a thinner bar than `MIN_ROWS_FOR_DRAFT_SLOT` (which is
# about one *position* across the whole catalog, not one team's actual roster depth).
DRAFT_SPIN_MIN_ROSTER = 8


def theme_health(theme: Theme, seasons: list[RawSeason],
                 baselines: BaselineTable | None = None) -> dict:
    """Pool/coverage stats for one theme (pure; mirrors grade_pool's own filtering)."""
    eligible = below_floor = filtered_out = 0
    for s in seasons:
        if s.sport != theme.sport or s.position not in theme.positions:
            continue
        s_grain = "career" if s.career else ("game" if s.week is not None else "season")
        if s_grain != theme.grain:
            continue
        eligible += 1
        if any(s.stats.get(k, 0.0) < v for k, v in theme.min_stats.items()):
            below_floor += 1
        elif not all(f.matches(s) for f in theme.filters):
            filtered_out += 1

    pool = grade_pool(theme, seasons, baselines)

    # Era coverage gap: pool years whose (sport, position, fantasy_total) baseline is
    # missing — those grades silently fell back to the global mean.
    gap_years: list[int] = []
    if theme.era_adjusted and baselines is not None:
        gap_years = sorted({
            s.season_year for s, _ in pool
            if baselines.era_mean(theme.sport, s.position, FANTASY_TOTAL_STAT,
                                  s.season_year) is None
        })

    return {
        "key": theme.key,
        "title": theme.title,
        "sport": theme.sport,
        "grain": theme.grain,
        "eligible_seasons": eligible,
        "excluded_by_min_stats": below_floor,
        "excluded_by_filters": filtered_out,
        "pool_size": len(pool),
        "pool_cap": theme.pool_cap,
        "puzzle_capable": len(pool) >= KEEP_COUNT,
        "era_adjusted": theme.era_adjusted,
        "era_baseline_gap_years": gap_years,
    }


def catalog_depth_report(seasons: list[RawSeason]) -> list[dict]:
    """Season-grain row counts per (sport, position), flagging any Draft & Spin lineup-slot
    position that's too thin to reliably deal 3 distinct daily candidates. Counts every
    season row regardless of theme eligibility (unlike `theme_health`, which filters by a
    specific theme's min-stats floor) — this is about raw catalog depth, the thing that was
    actually missing when soccer's GK/DF slots broke."""
    counts: collections.Counter[tuple[str, str]] = collections.Counter()
    for s in seasons:
        if not s.career and s.week is None:
            counts[(s.sport, s.position)] += 1

    rows = []
    for sport, position in sorted(DRAFT_SPIN_SLOT_POSITIONS):
        count = counts.get((sport, position), 0)
        rows.append({
            "sport": sport,
            "position": position,
            "season_rows": count,
            "draft_slot_viable": count >= MIN_ROWS_FOR_DRAFT_SLOT,
        })
    return rows


def thin_team_seasons(seasons: list[RawSeason],
                      min_roster: int = DRAFT_SPIN_MIN_ROSTER) -> list[dict]:
    """Season-grain soccer rows grouped by (team_abbr, season_year, league), flagging
    every combo with fewer than `min_roster` real player-seasons — the club-code
    collision bug's blast radius made visible: a team/season/league combo that's
    artificially thin (or, before the fix, artificially padded by a DIFFERENT club's
    rows under the same code) shows up here. Informational only — callers must not use
    this to filter the catalog, only to surface a health signal in content_health.json.

    Only `sport == "soccer"` rows are considered (this is soccer's Draft & Spin formation
    depth check specifically — see `DRAFT_SPIN_MIN_ROSTER`); career/game-grain rows are
    excluded the same way `catalog_depth_report` excludes them."""
    counts: collections.Counter[tuple[str, int, str]] = collections.Counter()
    for s in seasons:
        if s.sport != "soccer" or s.career or s.week is not None:
            continue
        league = s.meta.get("league", "")
        counts[(s.team_abbr, s.season_year, league)] += 1

    thin = [
        {"team_abbr": team_abbr, "season_year": season_year, "league": league,
         "roster_size": count}
        for (team_abbr, season_year, league), count in counts.items()
        if count < min_roster
    ]
    thin.sort(key=lambda r: (r["roster_size"], r["team_abbr"], r["season_year"]))
    return thin


def build_report(theme_stats: list[dict], keep4_built: dict[str, int],
                 whoami_count: int, catalog_depth: list[dict] | None = None,
                 thin_teams: list[dict] | None = None) -> dict:
    """Assemble the run-level artifact from per-theme stats + actual puzzle counts."""
    themes = [dict(t, puzzles_built=keep4_built.get(t["key"], 0)) for t in theme_stats]
    catalog_depth = catalog_depth or []
    thin_teams = thin_teams or []
    return {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "totals": {
            "themes": len(themes),
            "themes_below_pool_floor": sum(1 for t in themes if not t["puzzle_capable"]),
            "themes_with_era_gaps": sum(1 for t in themes if t["era_baseline_gap_years"]),
            "keep4_puzzles": sum(keep4_built.values()),
            "whoami_puzzles": whoami_count,
            "draft_slot_positions_too_thin": sum(1 for c in catalog_depth if not c["draft_slot_viable"]),
            "thin_team_seasons": len(thin_teams),
        },
        "themes": themes,
        "catalog_depth": catalog_depth,
        # Informational only (see `thin_team_seasons()`'s docstring) — never used to
        # filter the catalog. Capped to the 10 thinnest combos so the artifact doesn't
        # balloon when soccer coverage is broadly shallow; `totals.thin_team_seasons`
        # above still carries the full count.
        "thin_team_seasons_worst": thin_teams[:10],
    }


def write_report(report: dict, path: Path) -> None:
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")
