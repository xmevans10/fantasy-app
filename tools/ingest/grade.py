"""Grade derivation — real stats -> a quality score used to rank player-seasons
(raw fantasy points for every shipped theme; a legacy 0-100 weighted score for
the unused fixed scales).

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

Every shipped theme (daily and community) grades by **true fantasy points** rather
than the per-stat weighted scale above (`_FANTASY`) — ranking by actual PPR/QB/DK
totals fixed an audited bug where the old 0-100 `nfl_wr` scale buried reception/TD-heavy
seasons (e.g. Antonio Brown 2018 ranked #39 by grade but #26 by PPR):

    grade = round(sum(stat_i * per_unit_i), 1)

The grade *is* the raw fantasy total — no min-max normalization. The app displays this
number as-is (with a note that it's PPR/fantasy scoring) instead of squashing it onto an
artificial 0-100 band; a sport's typical magnitude (an NFL season ~330, an NBA per-game
~63) is part of what the number means. The sign of a penalty (e.g. interceptions) lives
in its coefficient. The Swift ports (`GradeFormula`, `ScoringRule`) mirror this
byte-for-byte.
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
    # NFL, any position — full PPR including passing. One formula for every NFL
    # player, so cross-position pools (QB vs WR vs RB) are judged on the same axis.
    "nfl_fantasy": [
        ("passing_yards", 0.04),
        ("passing_tds", 4.0),
        ("interceptions", -2.0),
        ("receptions", 1.0),
        ("receiving_yards", 0.1),
        ("receiving_tds", 6.0),
        ("rushing_yards", 0.1),
        ("rushing_tds", 6.0),
    ],
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
    # Baseball hitters — total-bases-derived points (hit=1, +1/+2/+3 per extra base,
    # matching standard points-league scoring) plus runs/RBI/walks/steals.
    "baseball_hitter_fantasy": [
        ("hits", 1.0),
        ("doubles", 1.0),
        ("triples", 2.0),
        ("home_runs", 3.0),
        ("runs", 1.0),
        ("rbi", 1.0),
        ("base_on_balls", 1.0),
        ("stolen_bases", 2.0),
    ],
    # Baseball pitchers — standard points-league weights (workload + strikeouts +
    # wins/saves, penalized by earned runs/walks).
    "baseball_pitcher_fantasy": [
        ("innings_pitched", 1.0),
        ("strike_outs", 1.0),
        ("wins", 5.0),
        ("saves", 6.0),
        ("earned_runs", -1.0),
        ("base_on_balls", -0.5),
    ],
    # Soccer attackers/midfielders — Fantasy Premier League's public scoring
    # convention (goal=4-6 by position, assist=3), simplified to one shared rate.
    "soccer_attacker_fantasy": [
        ("goals", 5.0),
        ("assists", 3.0),
        ("appearances", 1.0),
    ],
    # Soccer defenders/keepers — clean sheets are the headline stat (FPL awards
    # defenders/keepers points per clean sheet); goals/assists still count.
    "soccer_defender_fantasy": [
        ("clean_sheets", 4.0),
        ("goals", 6.0),
        ("assists", 3.0),
        ("appearances", 0.5),
    ],
    # Tennis — a full season's résumé: match wins are the bulk of the total, Grand
    # Slam titles dominate (30 pts each), regular titles matter, losses cost a little.
    "tennis_fantasy": [
        ("matches_won", 1.0),
        ("titles", 8.0),
        ("grand_slams", 30.0),
        ("matches_lost", -0.5),
    ],
}

# Single-game grain reuses the season coefficients (same PPR math) under their own keys —
# a game total just lands at a naturally smaller magnitude than a season total.
_FANTASY["nfl_fantasy_game"] = _FANTASY["nfl_fantasy"]
_FANTASY["nfl_skill_ppr_game"] = _FANTASY["nfl_skill_ppr"]
_FANTASY["nfl_qb_fantasy_game"] = _FANTASY["nfl_qb_fantasy"]


def _component(value: float, lo: float, hi: float, invert: bool) -> float:
    if invert:
        frac = (hi - value) / (hi - lo)
    else:
        frac = (value - lo) / (hi - lo)
    return 100.0 * max(0.0, min(1.0, frac))


def grade(stats: dict[str, float], scale_key: str) -> float:
    """Map a player-season's raw `stats` to a quality score used to rank it.

    `scale_key` selects the reference scale (e.g. 'nfl_rb', 'nba_scorer') or a
    fantasy-point scale (e.g. 'nfl_skill_ppr') — it is the theme's `scale` field,
    so a theme controls how its pool is judged. Fantasy-point scales return the
    raw point total (no normalization); the fixed scales above stay 0-100.
    """
    if scale_key in _FANTASY:
        raw = sum(stats.get(k, 0.0) * per for k, per in _FANTASY[scale_key])
        return round(raw, 1)
    if scale_key not in _SCALES:
        raise KeyError(f"unknown grade scale: {scale_key!r}")
    total = 0.0
    for stat_key, lo, hi, weight, invert in _SCALES[scale_key]:
        total += weight * _component(stats.get(stat_key, 0.0), lo, hi, invert)
    return round(total, 1)


def scale_keys() -> list[str]:
    return list(_SCALES) + list(_FANTASY)


# ── Era-adjusted fantasy grading (M10) ────────────────────────────────────────
#
# The era adjustment is a SINGLE per-(sport, position, year) volume index applied to
# the season's whole fantasy total — not per-stat multipliers. tools/ingest/era_analysis.py
# validated this shape on the full catalog: a total index is a monotonic rescale inside
# each position-year (it can never reorder two same-position same-year seasons), while
# per-stat recorder-mean ratios are noisy for secondary stats and DO reorder them.
#
# The index is defined over the shipped `stat_baselines.json` artifact so Swift
# (`ScoringRule.eraTotalIndex`) and Python compute the identical number. Its sole input
# is the `fantasy_total` pseudo-stat baselines.py emits — the distribution of unified
# fantasy totals over QUALIFY-gated (full-time) seasons per (sport, position, year):
#
#   index = globalMean(fantasy_total) / eraMean(fantasy_total, year)
#
# where globalMean is the count-weighted mean across years (StatBaselines.globalMean).
# Qualified populations matter: raw recorder means are diluted by cameo seasons and by
# population growth over the years, which flips the index's story. Era row missing, too
# thin (count < MIN_ERA_SAMPLES), or non-positive means → 1.0 (raw points, no adjustment).

MIN_ERA_SAMPLES = 8   # mirrors ScoringRule.minBaselineSamples


class BaselineTable:
    """Lookup over stat_baselines rows: era means + count-weighted global means."""

    def __init__(self, rows: list[dict]):
        self._era: dict[tuple[str, str, str, int], tuple[float, int]] = {}
        sums: dict[tuple[str, str, str], list[float]] = {}
        for r in rows:
            key = (r["sport"], r["position"], r["stat"], r["year"])
            self._era[key] = (float(r["mean"]), int(r["count"]))
            s = sums.setdefault((r["sport"], r["position"], r["stat"]), [0.0, 0.0])
            s[0] += float(r["mean"]) * int(r["count"])
            s[1] += int(r["count"])
        self._global = {k: (w / n if n else 0.0) for k, (w, n) in sums.items()}

    def era_mean(self, sport: str, position: str, stat: str, year: int) -> tuple[float, int] | None:
        return self._era.get((sport, position, stat, year))

    def global_mean(self, sport: str, position: str, stat: str) -> float | None:
        return self._global.get((sport, position, stat))


FANTASY_TOTAL_STAT = "fantasy_total"   # pseudo-stat emitted by baselines.py


def era_index(scale_key: str, sport: str, position: str, year: int,
              baselines: BaselineTable) -> float:
    """The fantasy-total volume index for a position-year (>1 = scarcer era)."""
    if scale_key not in _FANTASY:
        raise KeyError(f"era_index needs a fantasy scale, got {scale_key!r}")
    era = baselines.era_mean(sport, position, FANTASY_TOTAL_STAT, year)
    glob = baselines.global_mean(sport, position, FANTASY_TOTAL_STAT)
    if era is None or glob is None or era[1] < MIN_ERA_SAMPLES:
        return 1.0
    if era[0] <= 0 or glob <= 0:
        return 1.0
    return glob / era[0]


def grade_era(stats: dict[str, float], scale_key: str, sport: str, position: str,
              year: int, baselines: BaselineTable) -> float:
    """Era-adjusted fantasy grade: raw total × the position-year volume index."""
    raw = sum(stats.get(k, 0.0) * per for k, per in _FANTASY[scale_key])
    return round(raw * era_index(scale_key, sport, position, year, baselines), 1)
