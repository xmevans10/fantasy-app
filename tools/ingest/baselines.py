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

from .models import RawSeason

# Only (sport, position, stat, year) groups with at least this many samples are emitted;
# the client additionally ignores any below ScoringRule.minBaselineSamples.
MIN_SAMPLES = 5


def compute_baselines(seasons: list[RawSeason]) -> list[dict]:
    """Aggregate (sport, position, stat, year) → mean/std/count over recorders of the stat."""
    buckets: dict[tuple[str, str, str, int], list[float]] = defaultdict(list)
    for s in seasons:
        for stat, value in s.stats.items():
            # value > 0 keeps the population to players who actually produced the stat;
            # a 0 almost always means "not this player's role" (a lineman's receiving_yards).
            if value and value > 0:
                buckets[(s.sport, s.position, stat, s.season_year)].append(float(value))

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
