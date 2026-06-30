"""Theme catalog — editorial Keep4/Cut4 themes resolved to real-data queries.

Each theme narrows the provider pool (sport / position / minimum thresholds),
grades the survivors with a named `scale` (see grade.py), and declares which raw
stats to surface as the on-card `StatLine`s. assemble.py then slices 8 seasons
that are *close in grade* so the blind sort is non-trivial.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class StatColumn:
    stat: str       # raw stat key in RawSeason.stats
    label: str      # on-card label, e.g. "Rec Yds"
    fmt: str        # 'comma_int' | 'int' | 'dec1'


@dataclass(frozen=True)
class Theme:
    key: str
    title: str
    sport: str                       # 'nfl' | 'nba'
    scale: str                       # grade.py scale key
    positions: frozenset[str]
    min_stats: dict[str, float]      # inclusion thresholds (>=)
    columns: list[StatColumn]
    pool_cap: int = 16               # keep the top-N graded seasons as candidates
    max_variants: int = 6            # how many distinct 8-card puzzles to cut


def _fmt_value(value: float, fmt: str) -> str:
    if fmt == "comma_int":
        return f"{int(round(value)):,}"
    if fmt == "int":
        return f"{int(round(value))}"
    if fmt == "dec1":
        return f"{value:.1f}"
    if fmt == "pct1":               # fraction → one-decimal percent, e.g. 0.612 → "61.2"
        return f"{value * 100:.1f}"
    raise ValueError(f"unknown fmt {fmt!r}")


def format_columns(theme: Theme, stats: dict[str, float]) -> list[dict[str, str]]:
    """Build the camelCase `stats` array for a PlayerSeason card."""
    return [
        {"label": col.label, "value": _fmt_value(stats.get(col.stat, 0.0), col.fmt)}
        for col in theme.columns
    ]


KEEP4_THEMES: list[Theme] = [
    # ── NFL (live nflverse) ────────────────────────────────────────────
    Theme(
        key="nfl-wr-receiving",
        title="Elite WR receiving seasons",
        sport="nfl",
        scale="nfl_skill_ppr",
        positions=frozenset({"WR"}),
        min_stats={"receiving_yards": 1000, "games": 10},
        columns=[
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
            StatColumn("ypr", "Yds/Rec", "dec1"),
            StatColumn("targets", "Tgts", "int"),
        ],
    ),
    Theme(
        key="nfl-rb-workhorse",
        title="Workhorse RB seasons",
        sport="nfl",
        scale="nfl_skill_ppr",
        positions=frozenset({"RB"}),
        min_stats={"rushing_yards": 1100, "carries": 200},
        columns=[
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
            StatColumn("ypc", "Yds/Carry", "dec1"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
        ],
    ),
    Theme(
        key="nfl-qb-mvp",
        title="MVP-caliber QB seasons",
        sport="nfl",
        scale="nfl_qb_fantasy",
        positions=frozenset({"QB"}),
        min_stats={"passing_yards": 3800, "passing_tds": 28},
        columns=[
            StatColumn("passing_yards", "Pass Yds", "comma_int"),
            StatColumn("passing_tds", "Pass TD", "int"),
            StatColumn("interceptions", "INT", "int"),
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
        ],
    ),
    # ── NBA (seed today; balldontlie when keyed) ───────────────────────
    Theme(
        key="nba-scorers",
        title="Elite scoring seasons",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"G", "F", "C"}),
        min_stats={"ppg": 26.0},
        columns=[
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("apg", "APG", "dec1"),
            StatColumn("spg", "SPG", "dec1"),
            StatColumn("ts_pct", "TS%", "pct1"),
        ],
    ),
    Theme(
        key="nba-bigs",
        title="Dominant big-man seasons",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"F", "C"}),
        min_stats={"rpg": 9.5},
        columns=[
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("bpg", "BPG", "dec1"),
            StatColumn("apg", "APG", "dec1"),
            StatColumn("ts_pct", "TS%", "pct1"),
        ],
    ),
    Theme(
        key="nba-playmakers",
        title="Floor-general seasons",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"G", "F", "C"}),
        min_stats={"apg": 7.0},
        columns=[
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("apg", "APG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("spg", "SPG", "dec1"),
            StatColumn("ts_pct", "TS%", "pct1"),
        ],
    ),
]
