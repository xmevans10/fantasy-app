"""Theme catalog — editorial Keep4/Cut4 themes resolved to real-data queries.

Each theme narrows the provider pool (sport / position / minimum thresholds),
grades the survivors with a named `scale` (see grade.py), and declares which raw
stats to surface as the on-card `StatLine`s. assemble.py then slices 8 seasons
that are *close in grade* so the blind sort is non-trivial.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass(frozen=True)
class StatColumn:
    stat: str       # raw stat key in RawSeason.stats
    label: str      # on-card label, e.g. "Rec Yds"
    fmt: str        # 'comma_int' | 'int' | 'dec1' | 'pct1'


def _coerce_num(v: object) -> float | None:
    try:
        return float(v)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def field_value(season, field_name: str) -> object:
    """Resolve a filter field off a RawSeason, checking computed fields first, then raw
    `stats`, then the `meta` bio bag. Keeps name/era/position filters data-free (derived
    from fields the season already has) while draft/college/height/age come from `meta`."""
    if field_name == "first_name":
        return season.meta.get("first_name") or (season.name.split() or [""])[0]
    if field_name == "last_name":
        return season.meta.get("last_name") or (season.name.split() or [""])[-1]
    if field_name == "season_year":
        return season.season_year
    if field_name == "decade":
        return (season.season_year // 10) * 10
    if field_name == "is_rookie_season":
        rookie_year = season.meta.get("rookie_season")
        return rookie_year is not None and str(season.season_year) == str(rookie_year)
    if field_name == "position":
        return season.position
    if field_name == "team":
        return season.team_abbr
    if field_name == "sport":
        return season.sport
    if field_name == "week":
        return season.week
    if field_name in season.stats:
        return season.stats.get(field_name)
    return season.meta.get(field_name)


@dataclass(frozen=True)
class Filter:
    """A declarative predicate over a RawSeason — the unit niche themes are built from.

    `field` is any name `field_value()` resolves (first_name, decade, college, draft_round,
    height_in, age, position, …). String compares are case-insensitive; numeric ops coerce.
    """
    field: str
    op: str                          # eq | in | range | gte | lte | regex | exists
    value: object = None

    def matches(self, season) -> bool:
        v = field_value(season, self.field)
        if self.op == "exists":       # value=True → require present; False → require absent
            present = v not in (None, "", "0", 0)
            return present == bool(self.value)
        if v in (None, ""):
            return False
        if self.op == "eq":
            nv, nt = _coerce_num(v), _coerce_num(self.value)
            if nv is not None and nt is not None:
                return nv == nt
            return str(v).lower() == str(self.value).lower()
        if self.op == "in":
            opts = {str(x).lower() for x in self.value}  # type: ignore[union-attr]
            return str(v).lower() in opts
        if self.op == "regex":
            return re.search(str(self.value), str(v), re.IGNORECASE) is not None
        num = _coerce_num(v)
        if num is None:
            return False
        if self.op == "gte":
            return num >= float(self.value)      # type: ignore[arg-type]
        if self.op == "lte":
            return num <= float(self.value)      # type: ignore[arg-type]
        if self.op == "range":
            lo, hi = self.value                  # type: ignore[misc]
            return lo <= num <= hi
        raise ValueError(f"unknown filter op {self.op!r}")


@dataclass(frozen=True)
class Theme:
    key: str
    title: str
    sport: str                       # 'nfl' | 'nba'
    scale: str                       # grade.py scale key
    positions: frozenset[str]
    min_stats: dict[str, float]      # inclusion thresholds (>=)
    columns: list[StatColumn]
    pool_cap: int = 24               # keep the top-N graded seasons as candidates
    max_variants: int = 1            # one puzzle per theme — no near-duplicate variants
    filters: tuple[Filter, ...] = () # extra niche predicates (bio/era/name); ANDed
    grain: str = "season"            # 'season' | 'game' (single-game rows) | 'career' (aggregate)
    # Grade with the era-adjusted fantasy total (grade.py grade_era): raw points × the
    # per-(position, year) volume index. Only meaningful for fantasy scales. NFL-only for
    # now — pre-2002 NBA baselines are survivorship-biased (see era_analysis.py findings).
    era_adjusted: bool = False


def _fmt_value(value: float, fmt: str) -> str:
    if fmt == "comma_int":
        return f"{int(round(value)):,}"
    if fmt == "int":
        return f"{int(round(value))}"
    if fmt == "dec1":
        return f"{value:.1f}"
    if fmt == "pct1":               # fraction → one-decimal percent, e.g. 0.612 → "61.2"
        return f"{value * 100:.1f}"
    if fmt == "dec3":               # rate stats that need 3 places, e.g. baseball AVG/OPS
        return f"{value:.3f}"
    if fmt == "dec2":               # rate stats conventionally shown to 2 places, e.g. ERA/WHIP
        return f"{value:.2f}"
    raise ValueError(f"unknown fmt {fmt!r}")


# Stat families an NFL position actually produces — drives per-position column selection
# for cross-position themes so a WR card never reads "Pass Yds 0".
_NFL_POSITION_STATS: dict[str, tuple[str, ...]] = {
    "QB": ("passing_", "rushing_", "interceptions", "completions", "attempts", "completion_pct"),
    "RB": ("rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr"),
    "FB": ("rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr"),
    "WR": ("receiving_", "receptions", "targets", "ypr"),
    "TE": ("receiving_", "receptions", "targets", "ypr"),
}


def columns_for(theme: Theme, position: str | None = None) -> list[StatColumn]:
    """The card columns for a season at `position`.

    Single-position(-family) themes always use the theme's columns as-is. For a
    cross-position NFL theme (e.g. nfl-total-fantasy), slice the columns to the stat
    families the position produces, so mixed pools read sensibly per card. Falls back
    to the full set if the slice would leave fewer than 3 columns.
    """
    if position is None or theme.sport != "nfl" or len(theme.positions) <= 1:
        return theme.columns
    prefixes = _NFL_POSITION_STATS.get(position)
    if not prefixes:
        return theme.columns
    sliced = [c for c in theme.columns if c.stat.startswith(prefixes)]
    return sliced if len(sliced) >= 3 else theme.columns


def format_columns(theme: Theme, stats: dict[str, float],
                   position: str | None = None) -> list[dict[str, str]]:
    """Build the camelCase `stats` array for a PlayerSeason card (position-aware for
    cross-position themes — see `columns_for`)."""
    return [
        {"label": col.label, "value": _fmt_value(stats.get(col.stat, 0.0), col.fmt)}
        for col in columns_for(theme, position)
    ]


def export_theme(theme: Theme) -> dict:
    """One theme as the camelCase JSON row the app's `Keep4Theme` Codable decodes.

    This export IS the shared template shape (M10): the creation flow consumes it so a
    community puzzle built from a theme carries the exact scale/positions/columns the
    daily pipeline uses. Stat keys (min_stats, columns[].stat) stay snake_case — they're
    data values that must match `RawSeason.stats` / `CatalogSeason.stats` keys.
    """
    return {
        "key": theme.key,
        "title": theme.title,
        "sport": theme.sport,
        "scale": theme.scale,
        "positions": sorted(theme.positions),
        "minStats": dict(sorted(theme.min_stats.items())),
        "columns": [{"stat": c.stat, "label": c.label, "fmt": c.fmt} for c in theme.columns],
        "poolCap": theme.pool_cap,
        "grain": theme.grain,
        "eraAdjusted": theme.era_adjusted,
    }


def export_themes(themes: list[Theme] | None = None) -> list[dict]:
    """All themes in bundle-export order (catalog order, stable)."""
    return [export_theme(t) for t in (KEEP4_THEMES if themes is None else themes)]


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
    Theme(
        key="nfl-qb-dual",
        title="Dual-threat QB seasons",
        sport="nfl",
        scale="nfl_qb_fantasy",
        positions=frozenset({"QB"}),
        # Real running QBs: meaningful passing volume *and* 400+ yards on the ground.
        min_stats={"passing_yards": 2600, "rushing_yards": 400},
        columns=[
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
            StatColumn("passing_yards", "Pass Yds", "comma_int"),
            StatColumn("passing_tds", "Pass TD", "int"),
            StatColumn("interceptions", "INT", "int"),
        ],
    ),
    Theme(
        key="nfl-rb-receiving",
        title="Pass-catching RB seasons",
        sport="nfl",
        scale="nfl_skill_ppr",
        positions=frozenset({"RB"}),
        # Backs who beat you through the air, not just on the ground.
        min_stats={"receptions": 55, "receiving_yards": 450},
        columns=[
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
        ],
    ),
    Theme(
        key="nfl-wr-deep",
        title="Big-play WR seasons",
        sport="nfl",
        scale="nfl_skill_ppr",
        positions=frozenset({"WR"}),
        # Field-stretchers: 900+ yards at a high yards-per-catch clip.
        min_stats={"receiving_yards": 900, "ypr": 15.5},
        columns=[
            StatColumn("ypr", "Yds/Rec", "dec1"),
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("targets", "Tgts", "int"),
        ],
    ),
    Theme(
        key="nfl-total-fantasy",
        title="All-time fantasy seasons — any position",
        sport="nfl",
        scale="nfl_fantasy",
        # Cross-position: one unified PPR formula judges QBs, RBs, WRs and TEs on the
        # same axis, so the pool is simply the best fantasy seasons ever, full stop.
        positions=frozenset({"QB", "RB", "WR", "TE"}),
        # Position-neutral gate (min_stats are ANDed, so any per-stat floor would zero
        # out the other positions); the unified grade + pool_cap pick the elite.
        min_stats={"games": 10},
        columns=[
            StatColumn("passing_yards", "Pass Yds", "comma_int"),
            StatColumn("passing_tds", "Pass TD", "int"),
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
        ],
    ),
    Theme(
        key="nfl-total-fantasy-era",
        title="Best seasons of all time — era-adjusted",
        sport="nfl",
        scale="nfl_fantasy",
        era_adjusted=True,
        # Same cross-position pool as nfl-total-fantasy, but the grade is raw PPR × the
        # per-(position, year) volume index, so a 2002 line can outrank a bigger 2022 one.
        positions=frozenset({"QB", "RB", "WR", "TE"}),
        min_stats={"games": 10},
        columns=[
            StatColumn("passing_yards", "Pass Yds", "comma_int"),
            StatColumn("passing_tds", "Pass TD", "int"),
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
        ],
    ),
    Theme(
        key="nfl-te-mismatch",
        title="Mismatch TE seasons",
        sport="nfl",
        scale="nfl_skill_ppr",
        positions=frozenset({"TE"}),
        # The position the old catalog never touched — receiving tight ends.
        min_stats={"receiving_yards": 650, "games": 10},
        columns=[
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
            StatColumn("ypr", "Yds/Rec", "dec1"),
            StatColumn("targets", "Tgts", "int"),
        ],
    ),
    # ── NBA (live ESPN pool — 800+ players via espn_nba_pool / pyespn) ───────
    Theme(
        key="nba-scorers",
        title="Elite scoring seasons",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"G", "F", "C"}),
        min_stats={"ppg": 26.0, "games": 40},
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
        min_stats={"rpg": 9.5, "games": 40},
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
        min_stats={"apg": 7.0, "games": 40},
        columns=[
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("apg", "APG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("spg", "SPG", "dec1"),
            StatColumn("ts_pct", "TS%", "pct1"),
        ],
    ),
    Theme(
        key="nba-rim-protectors",
        title="Rim-protector seasons",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"F", "C"}),
        min_stats={"bpg": 2.0, "games": 40},
        columns=[
            StatColumn("bpg", "BPG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("spg", "SPG", "dec1"),
            StatColumn("ts_pct", "TS%", "pct1"),
        ],
    ),
    Theme(
        key="nba-two-way-guards",
        title="Two-way guard seasons",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"G"}),
        min_stats={"spg": 1.8, "games": 40},
        columns=[
            StatColumn("spg", "SPG", "dec1"),
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("apg", "APG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("ts_pct", "TS%", "pct1"),
        ],
    ),
    Theme(
        key="nba-double-double",
        title="Double-double machine seasons",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"F", "C"}),
        min_stats={"ppg": 18.0, "rpg": 10.0, "games": 40},
        columns=[
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("apg", "APG", "dec1"),
            StatColumn("bpg", "BPG", "dec1"),
            StatColumn("ts_pct", "TS%", "pct1"),
        ],
    ),
    # ── NBA single-game (grain="game" — one row per player's one box score, via
    # providers/hoopr_nba_games.py). ─────────────────────────────────────────────
    Theme(
        key="nba-game-scoring-outburst",
        title="Historic single-game scoring outbursts",
        sport="nba",
        scale="nba_fantasy_game",
        positions=frozenset({"G", "F", "C"}),
        min_stats={"points": 40},
        grain="game",
        columns=[
            StatColumn("points", "PTS", "int"),
            StatColumn("field_goals_made", "FGM", "int"),
            StatColumn("rebounds", "REB", "int"),
            StatColumn("assists", "AST", "int"),
        ],
    ),
    Theme(
        key="nba-game-triple-double",
        title="Single-game triple-double explosions",
        sport="nba",
        scale="nba_fantasy_game",
        positions=frozenset({"G", "F", "C"}),
        min_stats={"points": 10},
        filters=(Filter(field="rebounds", op="gte", value=10),
                 Filter(field="assists", op="gte", value=10)),
        grain="game",
        columns=[
            StatColumn("points", "PTS", "int"),
            StatColumn("rebounds", "REB", "int"),
            StatColumn("assists", "AST", "int"),
            StatColumn("steals", "STL", "int"),
        ],
    ),
    # ── NFL single-game (grain="game" — one row per player's one game, via
    # providers/nfl_nflverse_games.py). The "biggest single game" angle the season
    # themes above can never express. ────────────────────────────────────────────
    Theme(
        key="nfl-game-rb-explosion",
        title="Explosive single-game RB performances",
        sport="nfl",
        scale="nfl_skill_ppr_game",
        positions=frozenset({"RB"}),
        min_stats={"rushing_yards": 120},
        grain="game",
        columns=[
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
            StatColumn("ypc", "Yds/Carry", "dec1"),
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
        ],
    ),
    Theme(
        key="nfl-game-wr-explosion",
        title="Explosive single-game WR performances",
        sport="nfl",
        scale="nfl_skill_ppr_game",
        positions=frozenset({"WR"}),
        min_stats={"receiving_yards": 130},
        grain="game",
        columns=[
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
            StatColumn("ypr", "Yds/Rec", "dec1"),
        ],
    ),
    Theme(
        key="nfl-game-qb-explosion",
        title="Explosive single-game QB performances",
        sport="nfl",
        scale="nfl_qb_fantasy_game",
        positions=frozenset({"QB"}),
        min_stats={"passing_yards": 300},
        grain="game",
        columns=[
            StatColumn("passing_yards", "Pass Yds", "comma_int"),
            StatColumn("passing_tds", "Pass TD", "int"),
            StatColumn("interceptions", "INT", "int"),
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        ],
    ),
    Theme(
        key="nfl-game-te-explosion",
        title="Big-play tight end games",
        sport="nfl",
        scale="nfl_skill_ppr_game",
        positions=frozenset({"TE"}),
        min_stats={"receiving_yards": 90},
        grain="game",
        columns=[
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
            StatColumn("ypr", "Yds/Rec", "dec1"),
        ],
    ),
    Theme(
        key="nfl-game-qb-rushing",
        title="Dual-threat QB rushing games",
        sport="nfl",
        scale="nfl_qb_fantasy_game",
        positions=frozenset({"QB"}),
        min_stats={"rushing_yards": 70},
        grain="game",
        columns=[
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
            StatColumn("passing_yards", "Pass Yds", "comma_int"),
            StatColumn("passing_tds", "Pass TD", "int"),
        ],
    ),
    # ── Baseball (live MLB Stats API, seed fallback) ─────────────────────
    Theme(
        key="baseball-power-hitters",
        title="Elite power-hitting seasons",
        sport="baseball",
        scale="baseball_hitter_fantasy",
        positions=frozenset({"H"}),
        min_stats={"plate_appearances": 300},
        columns=[
            StatColumn("home_runs", "HR", "int"),
            StatColumn("rbi", "RBI", "int"),
            StatColumn("avg", "AVG", "dec3"),
            StatColumn("ops", "OPS", "dec3"),
            StatColumn("runs", "R", "int"),
        ],
    ),
    Theme(
        key="baseball-ace-pitchers",
        title="Ace pitching seasons",
        sport="baseball",
        scale="baseball_pitcher_fantasy",
        positions=frozenset({"P"}),
        min_stats={"innings_pitched": 80},
        columns=[
            StatColumn("strike_outs", "K", "int"),
            StatColumn("wins", "W", "int"),
            StatColumn("era", "ERA", "dec2"),
            StatColumn("whip", "WHIP", "dec2"),
            StatColumn("innings_pitched", "IP", "dec1"),
        ],
    ),
    # ── Baseball single-game (grain="game" — one row per player's one game, via
    # providers/mlb_stats_games.py's `stats=gameLog` pull). ───────────────────────
    Theme(
        key="baseball-game-power-outburst",
        title="Multi-homer games",
        sport="baseball",
        scale="baseball_hitter_fantasy_game",
        positions=frozenset({"H"}),
        min_stats={"home_runs": 2},
        grain="game",
        columns=[
            StatColumn("home_runs", "HR", "int"),
            StatColumn("rbi", "RBI", "int"),
            StatColumn("hits", "Hits", "int"),
            StatColumn("runs", "R", "int"),
        ],
    ),
    Theme(
        key="baseball-game-ace-start",
        title="Dominant single-game pitching starts",
        sport="baseball",
        scale="baseball_pitcher_fantasy_game",
        positions=frozenset({"P"}),
        min_stats={"strike_outs": 8},
        filters=(Filter(field="earned_runs", op="lte", value=1),),
        grain="game",
        columns=[
            StatColumn("strike_outs", "K", "int"),
            StatColumn("earned_runs", "ER", "int"),
            StatColumn("innings_pitched", "IP", "dec1"),
            StatColumn("wins", "W", "int"),
        ],
    ),
    # ── Soccer (seed-only for now — no live club-stats source verified working;
    # see providers/seed.py's module docstring) ─────────────────────────
    Theme(
        key="soccer-attackers",
        title="Elite goal-scoring seasons",
        sport="soccer",
        scale="soccer_attacker_fantasy",
        positions=frozenset({"FW", "MF"}),
        min_stats={"appearances": 15},
        columns=[
            StatColumn("goals", "Goals", "int"),
            StatColumn("assists", "Assists", "int"),
            StatColumn("appearances", "Apps", "int"),
        ],
    ),
    Theme(
        key="soccer-defenders",
        title="Clean-sheet defender & keeper seasons",
        sport="soccer",
        scale="soccer_defender_fantasy",
        positions=frozenset({"DF", "GK"}),
        min_stats={"appearances": 15},
        columns=[
            StatColumn("clean_sheets", "Clean Sheets", "int"),
            StatColumn("appearances", "Apps", "int"),
            StatColumn("goals", "Goals", "int"),
            StatColumn("assists", "Assists", "int"),
        ],
    ),
    # ── Tennis (seed-only — no live source verified working; see
    # providers/seed.py's module docstring) ─────────────────────────────
    Theme(
        key="tennis-tour-dominance",
        title="Dominant tour seasons",
        sport="tennis",
        scale="tennis_fantasy",
        positions=frozenset({"Player"}),
        min_stats={"matches_won": 40},
        columns=[
            StatColumn("matches_won", "Wins", "int"),
            StatColumn("titles", "Titles", "int"),
            StatColumn("grand_slams", "Slams", "int"),
            StatColumn("matches_lost", "Losses", "int"),
        ],
    ),
    Theme(
        key="tennis-grand-slam",
        title="Grand Slam-era seasons",
        sport="tennis",
        scale="tennis_fantasy",
        positions=frozenset({"Player"}),
        min_stats={"grand_slams": 2},
        columns=[
            StatColumn("grand_slams", "Slams", "int"),
            StatColumn("titles", "Titles", "int"),
            StatColumn("matches_won", "Wins", "int"),
            StatColumn("matches_lost", "Losses", "int"),
        ],
    ),
    # ── Career aggregates (grain="career" — one row per player summing every real
    # season the pipeline pulled, via career.py's build_career_rows). Only shipped for
    # sports whose live providers pull deep multi-season history (NFL/NBA/MLB); soccer
    # and tennis are seed-only with ~1 season per player today, so there's no real
    # career signal to aggregate yet (career.py requires >=2 seasons per player-position
    # to emit a row — verified soccer produces zero, tennis produces 3, both too thin
    # for an 8-player pool). Revisit once those sports get a live multi-season source. ──
    Theme(
        key="nfl-career-fantasy",
        title="All-time career fantasy leaders",
        sport="nfl",
        scale="nfl_fantasy",
        positions=frozenset({"QB", "RB", "WR", "TE"}),
        min_stats={"games": 80},
        grain="career",
        columns=[
            StatColumn("passing_yards", "Pass Yds", "comma_int"),
            StatColumn("passing_tds", "Pass TD", "int"),
            StatColumn("rushing_yards", "Rush Yds", "comma_int"),
            StatColumn("rushing_tds", "Rush TD", "int"),
            StatColumn("receptions", "Rec", "int"),
            StatColumn("receiving_yards", "Rec Yds", "comma_int"),
            StatColumn("receiving_tds", "Rec TD", "int"),
        ],
    ),
    Theme(
        key="nba-career-fantasy",
        title="All-time career leaders",
        sport="nba",
        scale="nba_fantasy",
        positions=frozenset({"G", "F", "C"}),
        min_stats={"games": 300},
        grain="career",
        columns=[
            StatColumn("ppg", "PPG", "dec1"),
            StatColumn("rpg", "RPG", "dec1"),
            StatColumn("apg", "APG", "dec1"),
            StatColumn("spg", "SPG", "dec1"),
            StatColumn("bpg", "BPG", "dec1"),
        ],
    ),
    Theme(
        key="baseball-career-hitters",
        title="Career power-hitting leaders",
        sport="baseball",
        scale="baseball_hitter_fantasy",
        positions=frozenset({"H"}),
        min_stats={"plate_appearances": 3000},
        grain="career",
        columns=[
            StatColumn("home_runs", "HR", "comma_int"),
            StatColumn("rbi", "RBI", "comma_int"),
            StatColumn("avg", "AVG", "dec3"),
            StatColumn("ops", "OPS", "dec3"),
            StatColumn("runs", "R", "comma_int"),
        ],
    ),
    Theme(
        key="baseball-career-pitchers",
        title="Career pitching leaders",
        sport="baseball",
        scale="baseball_pitcher_fantasy",
        positions=frozenset({"P"}),
        min_stats={"innings_pitched": 800},
        grain="career",
        columns=[
            StatColumn("strike_outs", "K", "comma_int"),
            StatColumn("wins", "W", "int"),
            StatColumn("era", "ERA", "dec2"),
            StatColumn("whip", "WHIP", "dec2"),
            StatColumn("innings_pitched", "IP", "comma_int"),
        ],
    ),
]
