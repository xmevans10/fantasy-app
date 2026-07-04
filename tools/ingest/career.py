"""Career-grain aggregation — collapse every real season the pipeline pulled for a
player into one "career" `RawSeason` row per (sport, position), so a Keep4 theme can
grade/display career totals exactly like it does season or single-game rows.

Two kinds of stats need different math:
- **Counting stats** (yards, goals, wins, …) — a career total is just the sum across
  every season.
- **Rate stats** (AVG, ERA, PPG, …) — summing would be wrong (a .300/.280/.310 hitter
  isn't a .890 hitter). These are recomputed as a weighted average using each season's
  correct denominator (e.g. ERA weighted by innings pitched). This is exact, not an
  approximation: `sum(rate_i * weight_i) / sum(weight_i)` collapses back to the true
  aggregate ratio whenever `weight_i` is the stat's real denominator (e.g. ERA * IP =
  earned_runs * 9, so IP-weighted average ERA reduces to `9 * total_earned_runs /
  total_IP`, the actual definition). OBP is the one approximation: its true denominator
  (AB + BB + HBP + SF) isn't fully available (no HBP/SF tracked), so it's weighted by
  (AB + BB) — close, not exact. OPS is derived as career OBP + career SLG rather than
  weight-averaged directly, since OBP and SLG don't share one denominator.
"""
from __future__ import annotations

from collections import defaultdict

from .models import RawSeason, slug

# stat_key -> weighting denominator stat_key(s). Anything absent from this dict for a
# sport defaults to a plain sum (the common case: yards, TDs, goals, wins, ...).
_RATE_WEIGHTS: dict[str, dict[str, str | tuple[str, ...]]] = {
    "nfl": {
        "completion_pct": "attempts",
        "ypc": "carries",
        "ypr": "receptions",
    },
    "nba": {
        "ppg": "games", "rpg": "games", "apg": "games", "spg": "games", "bpg": "games",
        "fg_pct": "games",   # approximation: no raw FGM/FGA stored, games is the best proxy
        "ts_pct": "games",   # ditto
    },
    "baseball": {
        "avg": "at_bats",
        "slg": "at_bats",
        "obp": ("at_bats", "base_on_balls"),   # approximation: ignores HBP/SF (not tracked)
        "era": "innings_pitched",
        "whip": "innings_pitched",
    },
    "soccer": {},
    "tennis": {},
}

# Stats derived AFTER the weighted-average pass rather than averaged directly, because
# they don't share one clean denominator with their inputs.
_DERIVED = {
    "baseball": {"ops": ("obp", "slg")},   # career OPS = career OBP + career SLG
}

def _weight(stats: dict[str, float], key: str | tuple[str, ...]) -> float:
    if isinstance(key, tuple):
        return sum(stats.get(k, 0.0) for k in key)
    return stats.get(key, 0.0)


def _aggregate_stats(sport: str, rows: list[RawSeason]) -> dict[str, float]:
    """Sum counting stats; weighted-average rate stats; recompute derived stats last."""
    rate_weights = _RATE_WEIGHTS.get(sport, {})
    all_keys = {k for r in rows for k in r.stats}
    derived_keys = set(_DERIVED.get(sport, {}))
    out: dict[str, float] = {}
    for key in all_keys - derived_keys:
        if key in rate_weights:
            weight_key = rate_weights[key]
            total_weight = sum(_weight(r.stats, weight_key) for r in rows)
            if total_weight <= 0:
                out[key] = 0.0
                continue
            out[key] = round(
                sum(r.stats.get(key, 0.0) * _weight(r.stats, weight_key) for r in rows)
                / total_weight,
                3,
            )
        else:
            out[key] = round(sum(r.stats.get(key, 0.0) for r in rows), 3)
    for key, parts in _DERIVED.get(sport, {}).items():
        if any(p in all_keys for p in parts):   # skip e.g. pitchers, who have no obp/slg
            out[key] = round(sum(out.get(p, 0.0) for p in parts), 3)
    return out


def build_career_rows(seasons: list[RawSeason]) -> list[RawSeason]:
    """One aggregate row per (sport, position, player) summing every real season-grain
    row the pipeline pulled for them. Excludes single-game rows (`week` set) and any
    row that's already a career aggregate (idempotent if called twice)."""
    groups: dict[tuple[str, str, str], list[RawSeason]] = defaultdict(list)
    for s in seasons:
        if s.week is not None or s.career:
            continue
        groups[(s.sport, s.position, slug(s.name))].append(s)

    out: list[RawSeason] = []
    for (sport, position, _person), rows in groups.items():
        if len(rows) < 2:   # a "career" of one season isn't a distinct grain
            continue
        rows_by_year = sorted(rows, key=lambda r: r.season_year)
        latest, earliest = rows_by_year[-1], rows_by_year[0]
        stats = _aggregate_stats(sport, rows)
        meta = {
            "first_year": str(earliest.season_year),
            "last_year": str(latest.season_year),
            "seasons_played": str(len(rows)),
        }
        out.append(RawSeason(
            name=latest.name,
            team_abbr=latest.team_abbr,
            season_year=latest.season_year,
            sport=sport,
            position=position,
            stats=stats,
            source="career_aggregate",
            headshot=latest.headshot,
            career=True,
            meta=meta,
        ))
    return out
