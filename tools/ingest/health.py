"""Content-health artifact (M15).

The per-theme pool/coverage stats the pipeline always computed internally used to
exist only as ``--dry-run`` stdout. This module turns them into a durable
``content_health.json`` written on every run, answering: how deep is each theme's
candidate pool, how much did the min-stat floors and niche filters exclude, and do
era-adjusted themes have baseline coverage for every season they graded.
"""
from __future__ import annotations

import datetime as dt
import json
from pathlib import Path

from .assemble import KEEP_COUNT, grade_pool
from .grade import FANTASY_TOTAL_STAT, BaselineTable
from .models import RawSeason
from .themes import Theme


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


def build_report(theme_stats: list[dict], keep4_built: dict[str, int],
                 whoami_count: int) -> dict:
    """Assemble the run-level artifact from per-theme stats + actual puzzle counts."""
    themes = [dict(t, puzzles_built=keep4_built.get(t["key"], 0)) for t in theme_stats]
    return {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "totals": {
            "themes": len(themes),
            "themes_below_pool_floor": sum(1 for t in themes if not t["puzzle_capable"]),
            "themes_with_era_gaps": sum(1 for t in themes if t["era_baseline_gap_years"]),
            "keep4_puzzles": sum(keep4_built.values()),
            "whoami_puzzles": whoami_count,
        },
        "themes": themes,
    }


def write_report(report: dict, path: Path) -> None:
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")
