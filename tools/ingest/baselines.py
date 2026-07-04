"""Per-(sport, stat, season-year) stat distributions for era-adjusted scoring.

The creation flow can rank a stat *relative to its season's distribution* (z-score)
so cross-era Keep4 themes — "best WRs of the 2010s" — are judged fairly: 1,400
receiving yards in 2004 and 2024 land at different percentiles of their own seasons.

These baselines are computed from the **full** raw season pull (every player the
provider returned that year), not the curated `player_seasons` catalog, which is too
thin per year to be a credible distribution.

The population for a given stat is keyed by **(sport, position, stat, year)** over
seasons that actually *recorded* it (value > 0). Position matters: a WR's 1,400
receiving yards must be judged against *receivers* that year, not against every RB and
TE who caught a pass — otherwise every real WR z-scores off the chart and the Keep/Cut
signal collapses. Comparing each season within its own position-year is also the right
behavior for mixed-position themes ("how elite was this season *for that position*").

Output: a flat array bundled as `BallIQ/Data/stat_baselines.json`, decoded by the
Swift `StatBaselines` loader. Rows: {sport, position, stat, year, mean, std, count}.
"""
from __future__ import annotations

import statistics
from collections import defaultdict

from .grade import grade
from .models import RawSeason

# Only (sport, position, stat, year) groups with at least this many samples are emitted;
# the client additionally ignores any below ScoringRule.minBaselineSamples.
MIN_SAMPLES = 5

# Population gate for the `fantasy_total` pseudo-stat: full-time seasons only, so the
# era volume index isn't diluted by cameo seasons (mirrors era_analysis.py QUALIFY).
QUALIFY = {"nfl": ("games", 10.0), "nba": ("games", 40.0)}
TOTAL_SCALE = {"nfl": "nfl_fantasy", "nba": "nba_fantasy"}

# Pseudo-stat key for the per-(sport, position, year) fantasy-total distribution — the
# single input to the era volume index (grade.era_index / ScoringRule.eraTotalIndex).
FANTASY_TOTAL = "fantasy_total"


def compute_baselines(seasons: list[RawSeason]) -> list[dict]:
    """Aggregate (sport, position, stat, year) → mean/std/count over recorders of the stat.

    Season grain only — a game-grain row (week set) is one player's single game, and a
    career row is a whole career's aggregate; mixing either into a season distribution
    catastrophically dilutes it (a 2015 WR "mean" of 85 receiving yards over 1,900
    "recorders" that were actually games, or a career total of 15,000 yards blowing out
    the scale entirely).

    Also emits a `fantasy_total` pseudo-stat per (sport, position, year): the unified
    fantasy-point total over QUALIFY-gated full-time seasons — the era volume index's
    sole input (definition validated by era_analysis.py).
    """
    buckets: dict[tuple[str, str, str, int], list[float]] = defaultdict(list)
    for s in seasons:
        if s.week is not None or s.career:   # never mix single games or careers into season distributions
            continue
        for stat, value in s.stats.items():
            # value > 0 keeps the population to players who actually produced the stat;
            # a 0 almost always means "not this player's role" (a lineman's receiving_yards).
            if value and value > 0:
                buckets[(s.sport, s.position, stat, s.season_year)].append(float(value))
        gate = QUALIFY.get(s.sport)
        if gate and s.position and s.stats.get(gate[0], 0.0) >= gate[1]:
            buckets[(s.sport, s.position, FANTASY_TOTAL, s.season_year)].append(
                grade(s.stats, TOTAL_SCALE[s.sport]))

    rows: list[dict] = []
    for (sport, position, stat, year), values in buckets.items():
        if len(values) < MIN_SAMPLES:
            continue
        rows.append({
            "sport": sport,
            "position": position,
            "stat": stat,
            "year": year,
            "mean": round(statistics.fmean(values), 4),
            # sample std (ddof=1); MIN_SAMPLES >= 5 guarantees len > 1.
            "std": round(statistics.stdev(values), 4),
            "count": len(values),
        })
    rows.sort(key=lambda r: (r["sport"], r["position"], r["stat"], r["year"]))
    return rows
