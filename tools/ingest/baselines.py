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
from typing import Callable

from .grade import grade
from .models import RawSeason

# Only (sport, position, stat, year) groups with at least this many samples are emitted;
# the client additionally ignores any below ScoringRule.minBaselineSamples.
MIN_SAMPLES = 5

# Population gate + grading scale for the `fantasy_total` pseudo-stat: full-time seasons
# only, so the era volume index isn't diluted by cameo seasons (mirrors era_analysis.py
# QUALIFY). Most sports have ONE fantasy scale, so a bare (stat, floor) / scale-key value
# applies to every position. A sport whose positions split across genuinely disjoint
# scales (hockey's skater/goalie, and — not yet enabled, see below — baseball's
# hitter/pitcher, soccer's attacker/defender) instead maps a ROLE name to its own gate/
# scale, and `_role()` resolves which role a raw position belongs to via `_POSITION_ROLE`.
#
# NFL/NBA are untouched by this: `QUALIFY.get(sport)`/`TOTAL_SCALE.get(sport)` still
# return the same plain tuple/string they always did, `_role()` is a no-op for them (no
# entry in `_POSITION_ROLE`), and `_qualify_gate`/`_total_scale` short-circuit on
# `isinstance(spec, dict)` being False — same lookup, same value, same baseline output.
QUALIFY: dict[str, tuple[str, float] | dict[str, tuple[str, float]]] = {
    "nfl": ("games", 10.0),
    "nba": ("games", 40.0),
    # NHL skaters: half of an 82-game season — the same bar NBA uses, since both leagues
    # play 82-game seasons, so a skater who dressed for fewer than half is a cameo/
    # injury/call-up year, not a full-time one.
    #
    # NHL goalies structurally can't clear that bar: even a true #1 splits starts with a
    # backup all but universally across NHL history, so goalies are gated on a lower,
    # role-appropriate floor — `games_started` (not `games`, which can include relief
    # appearances) at 25, which over the full 1917-2025 sweep keeps ~66% of goalie-seasons
    # (2,394/3,609) versus the skater gate's ~83% (29,999/35,924) of skater-seasons: a
    # tighter cut, because "primary starter" is a smaller share of a goalie's role than
    # "everyday player" is of a skater's.
    "hockey": {
        "skater": ("games", 40.0),
        "goalie": ("games_started", 25.0),
    },
}
TOTAL_SCALE: dict[str, str | dict[str, str]] = {
    "nfl": "nfl_fantasy",
    "nba": "nba_fantasy",
    "hockey": {"skater": "hockey_skater_fantasy", "goalie": "hockey_goalie_fantasy"},
}

# Maps a sport's raw position code to the ROLE bucket its QUALIFY/TOTAL_SCALE entry is
# keyed by, for sports whose scale is role-split rather than one-per-sport. A sport with a
# single unified scale (or no entry at all) never consults this — `_role()` just returns
# the raw position unchanged, which is a no-op lookup for `_qualify_gate`/`_total_scale`.
_POSITION_ROLE: dict[str, Callable[[str], str]] = {
    # NHL's goalie endpoint carries no positionCode field and every row from it is a
    # goalie by construction (see providers/nhl_stats.py); every other code (C/L/R/D) is
    # a skater.
    "hockey": lambda pos: "goalie" if pos == "G" else "skater",
}

# Pseudo-stat key for the per-(sport, position, year) fantasy-total distribution — the
# single input to the era volume index (grade.era_index / ScoringRule.eraTotalIndex).
FANTASY_TOTAL = "fantasy_total"


def _role(sport: str, position: str) -> str:
    """The ROLE bucket `position` belongs to, for role-split QUALIFY/TOTAL_SCALE entries.
    A no-op (`position` itself) for every sport without an entry in `_POSITION_ROLE`."""
    group = _POSITION_ROLE.get(sport)
    return group(position) if group else position


def _qualify_gate(sport: str, position: str) -> tuple[str, float] | None:
    spec = QUALIFY.get(sport)
    if isinstance(spec, dict):
        return spec.get(_role(sport, position))
    return spec


def _total_scale(sport: str, position: str) -> str | None:
    spec = TOTAL_SCALE.get(sport)
    if isinstance(spec, dict):
        return spec.get(_role(sport, position))
    return spec


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
        gate = _qualify_gate(s.sport, s.position) if s.position else None
        scale = _total_scale(s.sport, s.position) if s.position else None
        if gate and scale and s.stats.get(gate[0], 0.0) >= gate[1]:
            buckets[(s.sport, s.position, FANTASY_TOTAL, s.season_year)].append(
                grade(s.stats, scale))

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
