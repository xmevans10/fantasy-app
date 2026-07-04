"""M10 era-multiplier analysis — validate `.eraPoints` against the real catalog.

Answers three questions over the full raw pull (offline: providers serve from .cache/):

1. SHAPE — is per-stat `globalMean / eraMean` the right multiplier, or does a single
   per-(position, year) *fantasy-total* index behave better?
2. VALUES — what do the multipliers look like by year? Sanity-check famous seasons.
3. TRUST — where is the data too thin (the count >= 8 fallback)?

Run:  python -m tools.ingest.era_analysis

Findings (2026-07-01 run, summarized in docs/BALLIQ_SPEC.md):
- The single fantasy-total index wins. It is a monotonic rescale within each
  (position, year), so it can NEVER reorder two same-position same-year seasons —
  per-stat indices can and do (they re-weight stat mixes with noisy per-stat ratios).
- Per-stat indices are noisy for secondary stats (QB rushing, WR thin-stat recorder
  pools); the total index is smooth because big stable stats dominate the sum.
- count >= 8 is the right gate for the *total* index inputs: position-years below it
  are almost exclusively FB/TE fringe stats which the total index excludes anyway.
"""
from __future__ import annotations

import statistics
from collections import defaultdict

from .grade import _FANTASY, grade
from .models import RawSeason
from .providers import espn_nba, espn_nba_pool, nfl_nflverse

QUALIFY = {"nfl": ("games", 10), "nba": ("games", 40)}
SCALE_FOR = {"nfl": "nfl_fantasy", "nba": "nba_fantasy"}
MIN_COUNT = 8    # mirrors ScoringRule.minBaselineSamples


def load_seasons() -> list[RawSeason]:
    seasons = list(nfl_nflverse.fetch_years(list(range(1999, 2024))))
    pool = espn_nba_pool.load_pool()
    if pool:
        seasons += espn_nba.fetch_by_ids(pool)
    return [s for s in seasons if s.week is None]


def qualified(seasons: list[RawSeason]) -> list[RawSeason]:
    out = []
    for s in seasons:
        stat, floor = QUALIFY[s.sport]
        if s.stats.get(stat, 0) >= floor:
            out.append(s)
    return out


def total_index_table(seasons: list[RawSeason]) -> dict[tuple[str, str, int], tuple[float, int]]:
    """(sport, position, year) → (era volume index = globalMean/eraMean of fantasy total, n)."""
    totals: dict[tuple[str, str], dict[int, list[float]]] = defaultdict(lambda: defaultdict(list))
    for s in seasons:
        totals[(s.sport, s.position)][s.season_year].append(grade(s.stats, SCALE_FOR[s.sport]))
    table: dict[tuple[str, str, int], tuple[float, int]] = {}
    for (sport, pos), by_year in totals.items():
        counted = {y: v for y, v in by_year.items() if len(v) >= MIN_COUNT}
        if not counted:
            continue
        weighted = sum(statistics.fmean(v) * len(v) for v in counted.values())
        n_all = sum(len(v) for v in counted.values())
        global_mean = weighted / n_all
        for year, vals in counted.items():
            era_mean = statistics.fmean(vals)
            if era_mean > 0:
                table[(sport, pos, year)] = (global_mean / era_mean, len(vals))
    return table


def per_stat_index(seasons: list[RawSeason], sport: str, pos: str, stat: str,
                   year: int) -> float | None:
    """Current `.eraPoints` shape: recorder-mean ratio for one stat (None = fallback 1.0)."""
    era = [s.stats[stat] for s in seasons
           if s.sport == sport and s.position == pos and s.season_year == year
           and s.stats.get(stat, 0) > 0]
    alltime = [s.stats[stat] for s in seasons
               if s.sport == sport and s.position == pos and s.stats.get(stat, 0) > 0]
    if len(era) < MIN_COUNT or not alltime:
        return None
    era_mean = statistics.fmean(era)
    return statistics.fmean(alltime) / era_mean if era_mean > 0 else None


def grade_per_stat(seasons: list[RawSeason], s: RawSeason) -> float:
    """Era grade under the per-stat shape."""
    total = 0.0
    for stat, per in _FANTASY[SCALE_FOR[s.sport]]:
        idx = per_stat_index(seasons, s.sport, s.position, stat, s.season_year) or 1.0
        total += s.stats.get(stat, 0.0) * idx * per
    return round(total, 1)


def grade_total_idx(table, s: RawSeason) -> float:
    idx, _ = table.get((s.sport, s.position, s.season_year), (1.0, 0))
    return round(grade(s.stats, SCALE_FOR[s.sport]) * idx, 1)


def reorder_rate(seasons: list[RawSeason], sample: list[RawSeason]) -> int:
    """Count same-(sport,position,year) pairs whose order FLIPS under per-stat adjustment.
    The total index is a monotonic rescale within a position-year, so its flip count is 0
    by construction — every flip here is per-stat noise re-ranking a year's own players."""
    flips = 0
    by_year: dict[tuple[str, str, int], list[RawSeason]] = defaultdict(list)
    for s in sample:
        by_year[(s.sport, s.position, s.season_year)].append(s)
    for group in by_year.values():
        for i in range(len(group)):
            for j in range(i + 1, len(group)):
                a, b = group[i], group[j]
                raw = grade(a.stats, SCALE_FOR[a.sport]) - grade(b.stats, SCALE_FOR[b.sport])
                adj = grade_per_stat(seasons, a) - grade_per_stat(seasons, b)
                if raw * adj < 0:
                    flips += 1
    return flips


SANITY = [   # (sport, name-substring, year) — famous seasons inside the data window
    ("nfl", "Marvin Harrison", 2002),    # 143-rec season, pre-2004 rules
    ("nfl", "Priest Holmes", 2003),      # peak dead-era RB
    ("nfl", "Rich Gannon", 2002),        # MVP passing season, low-volume era
    ("nfl", "LaDainian Tomlinson", 2006),
    ("nfl", "Calvin Johnson", 2012),
    ("nfl", "Cooper Kupp", 2021),        # modern volume monster
    ("nfl", "Patrick Mahomes", 2022),
    ("nba", "Michael Jordan", 1996),     # pace-trough 90s
    ("nba", "Karl Malone", 1997),
    ("nba", "Allen Iverson", 2001),      # slowest-pace era in the window
    ("nba", "Nikola Jokic", 2022),       # modern pace/usage
    ("nba", "Luka Doncic", 2023),
]


def main() -> int:
    seasons = qualified(load_seasons())
    print(f"[era] {len(seasons)} qualified season rows")
    table = total_index_table(seasons)

    print("\n== Fantasy-total era index by year (globalMean/eraMean; >1 = scarcer era) ==")
    for sport, pos in [("nfl", "QB"), ("nfl", "RB"), ("nfl", "WR"), ("nfl", "TE"),
                       ("nba", "G"), ("nba", "F"), ("nba", "C")]:
        years = sorted(y for (sp, p, y) in table if sp == sport and p == pos)
        line = " ".join(f"{y % 100:02d}:{table[(sport, pos, y)][0]:.2f}" for y in years)
        print(f"{sport.upper()} {pos:2s} | {line}")

    print("\n== Sanity set: raw vs per-stat vs total-index era grades ==")
    print(f"{'season':34s} {'raw':>7s} {'perStat':>8s} {'totalIdx':>8s}")
    found: list[RawSeason] = []
    for sport, name, year in SANITY:
        m = [s for s in seasons if s.sport == sport and name.lower() in s.name.lower()
             and s.season_year == year]
        if not m:
            print(f"{name} {year}: NOT IN DATA")
            continue
        s = m[0]
        found.append(s)
        raw = grade(s.stats, SCALE_FOR[sport])
        print(f"{s.name} {year} ({s.position:2s})            "[:34]
              + f" {raw:7.1f} {grade_per_stat(seasons, s):8.1f} {grade_total_idx(table, s):8.1f}")

    flips = reorder_rate(seasons, found)
    print(f"\n[shape] per-stat method flips {flips} same-position-year sanity pairs "
          f"(total index flips 0 by construction)")

    thin = [(k, n) for k, (idx, n) in table.items() if n < 12]
    print(f"[trust] position-years with 8–11 qualified samples: {len(thin)} of {len(table)}")
    missing = defaultdict(int)
    for s in seasons:
        if (s.sport, s.position, s.season_year) not in table:
            missing[(s.sport, s.position)] += 1
    for k, n in sorted(missing.items()):
        print(f"[trust] no index (count<{MIN_COUNT}): {k} — {n} seasons fall back to 1.0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
