"""Grade derivation — real stats -> a 0-100 quality score.

The grade is the *hidden* number the app sorts by: in Keep4/Cut4 the four
highest-grade player-seasons are the correct "Keep" pile. So the grade must be
**defensible**: monotonic in each position's headline stat, and ordering must
match what a fan would read off Pro-Football-Reference / Basketball-Reference.

## How it works

Each (sport, position-family) has a small set of stats, each with a documented
reference scale `(lo, hi)` and a weight (weights sum to 1.0):

    component_i = 100 * clamp((stat_i - lo_i) / (hi_i - lo_i), 0, 1)
    grade       = round(sum(weight_i * component_i), 1)

`lo` ≈ a fringe-qualifying season, `hi` ≈ an all-time great season, so a typical
elite season lands in the 70-95 band. Because every component is linear and
non-decreasing in its stat (interceptions use an inverted scale — fewer is
better), the grade is **monotonic in the primary stat**: a 2,000-yard rusher
always outranks an 1,100-yard one at equal secondary stats.

The scales are intentionally simple, documented constants — not tuned weights —
so the ranking is auditable.

## Fantasy-point scales

Some themes grade by **true fantasy points** rather than the per-stat weighted scale
above (`_FANTASY`) — ranking by actual PPR/QB/DK totals fixed an audited bug where the
0-100 `nfl_wr` scale buried reception/TD-heavy seasons (e.g. Antonio Brown 2018 ranked
#39 by grade but #26 by PPR). The raw total is then min-maxed into the same familiar
0-100 scale as every other formula, using bounds documented per scale (`_FANTASY_BOUNDS`):

    raw   = sum(stat_i * per_unit_i)
    grade = round(100 * clamp((raw - lo) / (hi - lo), 0, 1), 1)

This is a strict monotonic transform of `raw`, so it changes nothing about *who wins*
the Keep/Cut split (the audit fix is preserved) — only the displayed number, which now
reads on the same 0-100 scale a fan expects everywhere else in the app, instead of a
points total that looked wildly different across sports (e.g. an NFL season total of
~330 next to an NBA per-game total of ~63). `lo`/`hi` follow the same spirit as the
fixed scales above — `lo` ≈ a fringe-qualifying season, `hi` ≈ an all-time-great one —
anchored to real percentiles/extremes of the full catalog (see comments at each bound).
The sign of a penalty (e.g. interceptions) lives in its coefficient. The Swift ports
(`GradeFormula`, `ScoringRule`) mirror this byte-for-byte.
"""
from __future__ import annotations

# (stat_key, lo, hi, weight, invert)
#   invert=True -> lower raw value scores higher (e.g. interceptions).
_SCALES: dict[str, list[tuple[str, float, float, float, bool]]] = {
    # NFL ---------------------------------------------------------------
    "nfl_wr": [
        ("receiving_yards", 850, 1950, 0.60, False),
        ("receiving_tds", 3, 19, 0.25, False),
        ("receptions", 60, 145, 0.15, False),
    ],
    "nfl_rb": [
        ("rushing_yards", 850, 2100, 0.60, False),
        ("rushing_tds", 4, 28, 0.25, False),
        ("ypc", 3.5, 6.2, 0.15, False),
    ],
    "nfl_qb": [
        ("passing_yards", 3000, 5500, 0.42, False),
        ("passing_tds", 18, 55, 0.40, False),
        ("interceptions", 4, 24, 0.18, True),
    ],
    # NBA ---------------------------------------------------------------
    "nba_scorer": [
        ("ppg", 20.0, 37.0, 0.68, False),
        ("ts_pct", 0.500, 0.670, 0.20, False),
        ("apg", 2.0, 11.0, 0.12, False),
    ],
    "nba_big": [
        ("ppg", 16.0, 30.0, 0.45, False),
        ("rpg", 8.0, 15.0, 0.35, False),
        ("bpg", 0.8, 3.7, 0.20, False),
    ],
    "nba_playmaker": [
        ("apg", 6.0, 14.5, 0.55, False),
        ("ppg", 12.0, 34.0, 0.30, False),
        ("ts_pct", 0.480, 0.660, 0.15, False),
    ],
}


# Fantasy-point scales: (stat_key, per_unit). grade = round(sum(stat * per_unit), 1).
#   No normalization/clamp — the grade is the raw fantasy total. A penalty's sign
#   lives in its coefficient (e.g. interceptions at -2).
_FANTASY: dict[str, list[tuple[str, float]]] = {
    # NFL skill (WR/RB/TE) — full PPR.
    "nfl_skill_ppr": [
        ("receptions", 1.0),
        ("receiving_yards", 0.1),
        ("receiving_tds", 6.0),
        ("rushing_yards", 0.1),
        ("rushing_tds", 6.0),
    ],
    # NFL QB — standard fantasy passing + rushing.
    "nfl_qb_fantasy": [
        ("passing_yards", 0.04),
        ("passing_tds", 4.0),
        ("interceptions", -2.0),
        ("rushing_yards", 0.1),
        ("rushing_tds", 6.0),
    ],
    # NBA — DraftKings-ish per-game (no TOV in the data).
    "nba_fantasy": [
        ("ppg", 1.0),
        ("rpg", 1.2),
        ("apg", 1.5),
        ("spg", 3.0),
        ("bpg", 3.0),
    ],
}

# Display bounds (lo, hi) the raw fantasy total is min-maxed into 0-100 against.
# Anchored to real data (full `player_seasons` catalog, seasons with meaningful playing
# time): lo sits near the fringe-qualifying floor, hi just above the actual observed
# ceiling so the all-time-best season lands just under 100, not pinned exactly at it.
_FANTASY_BOUNDS: dict[str, tuple[float, float]] = {
    # WR/RB/TE, games >= 8: p50 99.1, p90 227.8, p99 338.0, max 469.2 (an elite
    # dual-threat RB season). lo=40 ~ a fringe roster/part-timer floor.
    "nfl_skill_ppr": (40.0, 450.0),
    # QB, games >= 8: p50 232.2, p90 331.8, p99 402.4, max 422.0. lo=100 ~ a
    # below-average spot-starter floor.
    "nfl_qb_fantasy": (100.0, 450.0),
    # Per-game DK points. Bounds are reasoned from fantasy-basketball benchmarks
    # (replacement rotation player to a transcendent statistical season), not our
    # curated 34-season "legends" seed's own min/max — that sample already skews
    # great, so self-anchoring would break once a full-league live pull lands.
    "nba_fantasy": (15.0, 75.0),
}


def _component(value: float, lo: float, hi: float, invert: bool) -> float:
    if invert:
        frac = (hi - value) / (hi - lo)
    else:
        frac = (value - lo) / (hi - lo)
    return 100.0 * max(0.0, min(1.0, frac))


def grade(stats: dict[str, float], scale_key: str) -> float:
    """Map a player-season's raw `stats` to a 0-100 quality score.

    `scale_key` selects the reference scale (e.g. 'nfl_rb', 'nba_scorer') or a
    fantasy-point scale (e.g. 'nfl_skill_ppr') — it is the theme's `scale` field,
    so a theme controls how its pool is judged.
    """
    if scale_key in _FANTASY:
        raw = sum(stats.get(k, 0.0) * per for k, per in _FANTASY[scale_key])
        lo, hi = _FANTASY_BOUNDS[scale_key]
        frac = max(0.0, min(1.0, (raw - lo) / (hi - lo)))
        return round(100.0 * frac, 1)
    if scale_key not in _SCALES:
        raise KeyError(f"unknown grade scale: {scale_key!r}")
    total = 0.0
    for stat_key, lo, hi, weight, invert in _SCALES[scale_key]:
        total += weight * _component(stats.get(stat_key, 0.0), lo, hi, invert)
    return round(total, 1)


def scale_keys() -> list[str]:
    return list(_SCALES) + list(_FANTASY)
