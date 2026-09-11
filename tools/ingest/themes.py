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
    if field_name == "name":
        # The player's own name. Needed by the career-ladder shape, which is a theme ABOUT
        # one person ("rank eight Brady seasons") and therefore has to be able to select one;
        # every other field here narrows to a COHORT, so this was simply absent before.
        return season.name
    if field_name == "position":
        return season.position
    if field_name == "team":
        return season.team_abbr
    if field_name == "sport":
        return season.sport
    if field_name == "week":
        return season.week
    if field_name == "event_date":
        # ISO `YYYY-MM-DD`, so a lexicographic `range` compare IS a chronological one.
        # "" (season/career rows, dateless providers) resolves to None via the `in (None, "")`
        # guard in `Filter.matches`, so a period filter can never accidentally admit a row
        # that carries no date at all.
        return season.event_date or None
    if field_name == "period":
        return season.period or None
    if field_name == "color_family":
        # Joined onto `meta` by shapes.merge_team_colors from the `teams` table, not carried
        # by any provider. Absent when the join never ran, which correctly matches nothing.
        return season.meta.get("color_family")
    if field_name in season.stats:
        return season.stats.get(field_name)
    derived = _DERIVED.get(field_name)
    if derived is not None:
        return derived(season.stats)
    return season.meta.get(field_name)


def _ratio(num: float | None, den: float | None, scale: float = 1.0) -> float | None:
    """`num/den * scale`, or None when the denominator is missing or zero — a season with no
    innings pitched has no K/9, and inventing one would put it in a pool it does not belong to."""
    if num is None or not den:
        return None
    return (num / den) * scale


def _sum(stats: dict, *keys: str) -> float | None:
    present = [stats[k] for k in keys if stats.get(k) is not None]
    return sum(present) if len(present) == len(keys) else None


# Fields computed from the stat line rather than stored on it.
#
# These exist because the raw vocabularies are narrow — tennis stores four numbers, soccer
# four — and every quirk written against them is another threshold on the same stat. A rate
# is a different QUESTION: "who won 80% of their matches" is not "who won 60 matches", and it
# reaches seasons the counting stats cannot describe. Pure functions of `stats`, so they cost
# nothing to add and nothing to store.
_DERIVED: dict[str, object] = {
    # Soccer
    "goal_contributions": lambda st: _sum(st, "goals", "assists"),
    "goals_per_app": lambda st: _ratio(st.get("goals"), st.get("appearances")),
    # Baseball — hitters
    "extra_base_hits": lambda st: _sum(st, "doubles", "triples", "home_runs"),
    "iso": lambda st: (None if st.get("slg") is None or st.get("avg") is None
                       else st["slg"] - st["avg"]),
    # Baseball — pitchers. Rate stats are what separate a workhorse from a strikeout artist
    # once both clear an innings floor.
    "k_per_9": lambda st: _ratio(st.get("strike_outs"), st.get("innings_pitched"), 9.0),
    "bb_per_9": lambda st: _ratio(st.get("base_on_balls"), st.get("innings_pitched"), 9.0),
    "k_bb_ratio": lambda st: _ratio(st.get("strike_outs"), st.get("base_on_balls")),
    # NFL single-game
    "scrimmage_yards": lambda st: _sum(st, "rushing_yards", "receiving_yards"),
    "total_tds": lambda st: _sum(st, "rushing_tds", "receiving_tds"),
    "total_tds_all": lambda st: _sum(st, "rushing_tds", "receiving_tds", "passing_tds"),
    # NBA
    "stocks": lambda st: _sum(st, "spg", "bpg"),
    "pra": lambda st: _sum(st, "ppg", "rpg", "apg"),
    # Tennis — the whole point: four counting stats become rates and volume.
    "matches_played": lambda st: _sum(st, "matches_won", "matches_lost"),
    "win_pct": lambda st: _ratio(st.get("matches_won"),
                                 _sum(st, "matches_won", "matches_lost")),
}


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
        if self.op == "range":
            # Numeric when everything coerces (age 27-30, season_year 1990-2009); otherwise
            # an ordered STRING compare, which is what makes `event_date` windows work —
            # ISO `YYYY-MM-DD` sorts chronologically under a plain lexicographic compare, so
            # one op covers both without a parallel date-only operator.
            lo, hi = self.value                  # type: ignore[misc]
            num, nlo, nhi = _coerce_num(v), _coerce_num(lo), _coerce_num(hi)
            if num is not None and nlo is not None and nhi is not None:
                return nlo <= num <= nhi
            return str(lo) <= str(v) <= str(hi)
        num = _coerce_num(v)
        if num is None:
            return False
        if self.op == "gte":
            return num >= float(self.value)      # type: ignore[arg-type]
        if self.op == "lte":
            return num <= float(self.value)      # type: ignore[arg-type]
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
    # per-(position, year) volume index. Only meaningful for fantasy scales, and only for
    # sports baselines.py emits a `fantasy_total` pseudo-stat for (NFL, NBA, hockey as of
    # M31 — see baselines.py's QUALIFY/TOTAL_SCALE). Pre-2002 NBA baselines are
    # survivorship-biased (see era_analysis.py findings), so no shipped NBA theme uses this
    # yet even though the machinery supports it.
    era_adjusted: bool = False
    # How `assemble._windows` picks the eight rows out of the graded pool:
    #   'close'  — contiguous, grade-adjacent window. The default and the only mode before
    #              fresh drops existed; the blind sort is hard because the eight are close.
    #   'top'    — literally the top eight. What "Week 3: Top WR Performances" has to mean;
    #              a close window would quietly hand back the 9th-through-16th best instead.
    #   'spread' — eight sampled across the pool's YEAR range, so a franchise/career ladder
    #              spans its whole history instead of clustering in one peak era.
    # Every mode still requires the clean keep/cut boundary and the same-person check.
    window_mode: str = "close"
    # False lets ONE player hold several rows in the same puzzle — the career-ladder shape
    # ("rank eight Brady seasons"), which the default person-dedupe in `grade_pool` exists
    # precisely to prevent everywhere else. Only ever set False by a theme that is ABOUT one
    # player; leaving it on is what stops a star appearing twice on an ordinary card.
    dedupe_person: bool = True


def fmt_value(value: float, fmt: str) -> str:
    """Render a raw stat under one of the card `fmt` codes. Public because clue text needs
    the same rendering as a card column (see whoami_pool.stat_line) — one formatter, so a
    stat reads identically wherever it appears."""
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


# ── Per-position card composition (cross-position themes) ─────────────────────
#
# A cross-position pool mixes players whose stat vocabularies barely overlap, so ONE column
# list can't serve every card in it. Two tables drive the fix, both mirrored on the app side
# (`Sport.positionStatFamilies` / `Sport.positionStatTemplates` in BallIQ/Models/Sport.swift):
#
#   POSITION_STAT_FAMILIES — a *membership test*: the stat-key prefixes a position actually
#       records. Used to throw away a theme column the position can never produce.
#   POSITION_CARD — the *canonical stat card*: the ordered stat line a fan expects for that
#       position (the passing line for a QB, the receiving line for a WR/TE, G-A-P for a
#       hockey forward, the triple-crown categories for a hitter). This is what a card is
#       BUILT FROM, not merely filtered to.
#
# Why both, and why the canonical card leads: filtering alone can leave nothing to show. The
# generated NFL "ANY" themes cap at five columns (generate._MAX_COLUMNS), which truncates
# `receiving_yards`/`receiving_tds` off the seven-stat spec — so a TE's filter left exactly
# one surviving column (`receptions`), the old min-3 guard tripped, and the card fell back to
# the *unfiltered* set. That is how the live daily `gen-any-all-towering-09-daily-20260906`
# shipped Travis Kelce as "Pass Yds 0 · Pass TD 0 · Rush Yds 5 · Rush TD 0 · Rec 110" — four
# meaningless zeros, and neither of the two numbers that define his season. Building from the
# canonical card instead means a position's own stat line is always available to fill with,
# so there is no shape of theme for which the honest columns run out and junk gets served.
_NFL_DL_STATS = ("tackles_", "tackles_for_loss", "sacks", "qb_hits", "forced_fumbles",
                 "fumble_recoveries", "def_interceptions", "passes_defended",
                 "defensive_tds", "safeties", "games")
_NFL_LB_STATS = _NFL_DL_STATS
_NFL_DB_STATS = ("tackles_", "def_interceptions", "passes_defended", "forced_fumbles",
                 "fumble_recoveries", "defensive_tds", "safeties", "games")
_NHL_SKATER_STATS = ("goals", "assists", "points", "plus_minus", "penalty_minutes", "shots",
                     "shooting_pct", "points_per_game", "pp_points", "sh_points",
                     "game_winning_goals", "toi_per_game", "games")
_NHL_GOALIE_STATS = ("wins", "losses", "ot_losses", "gaa", "save_pct", "shutouts", "saves",
                     "shots_against", "goals_against", "games", "games_started")

POSITION_STAT_FAMILIES: dict[str, dict[str, tuple[str, ...]]] = {
    "nfl": {
        # `games` is on every one of these because every position plays them; `carries`/`ypc`
        # are on QB because a QB's rushing line is his, not a borrowed one. WR/TE deliberately
        # stay receiving-only even though 44% of WR seasons carry a non-zero rushing line
        # (measured over the bundled catalog): an end-around is incidental, and admitting it
        # would put a dead "Rush Yds 0" tile on the other 56%.
        "QB": ("passing_", "rushing_", "interceptions", "completions", "attempts",
               "completion_pct", "carries", "ypc", "games"),
        "RB": ("rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr", "games"),
        "FB": ("rushing_", "receiving_", "receptions", "targets", "carries", "ypc", "ypr", "games"),
        "WR": ("receiving_", "receptions", "targets", "ypr", "games"),
        "TE": ("receiving_", "receptions", "targets", "ypr", "games"),
        # Defensive groups collapse the ~13 granular codes nfl_nflverse_defense.py emits. No
        # shipped theme mixes defenders yet; they are here so the tables stay a true mirror of
        # Sport.swift's, which Draft & Spin's both-sides rosters already rely on.
        "DE": _NFL_DL_STATS, "DT": _NFL_DL_STATS, "NT": _NFL_DL_STATS, "DL": _NFL_DL_STATS,
        "OLB": _NFL_LB_STATS, "MLB": _NFL_LB_STATS, "ILB": _NFL_LB_STATS, "LB": _NFL_LB_STATS,
        "CB": _NFL_DB_STATS, "FS": _NFL_DB_STATS, "SS": _NFL_DB_STATS, "S": _NFL_DB_STATS,
        "SAF": _NFL_DB_STATS, "DB": _NFL_DB_STATS,
    },
    # Skaters and goalies are two disjoint vocabularies from two NHL endpoints
    # (see providers/nhl_stats.py) — a goalie card must never read "Goals 0".
    "hockey": {
        "C": _NHL_SKATER_STATS, "L": _NHL_SKATER_STATS,
        "R": _NHL_SKATER_STATS, "D": _NHL_SKATER_STATS,
        "G": _NHL_GOALIE_STATS,
    },
    "baseball": {
        "H": ("hits", "doubles", "triples", "home_runs", "runs", "rbi", "base_on_balls",
              "stolen_bases", "avg", "obp", "slg", "ops", "at_bats", "plate_appearances"),
        # A pitcher's walks ALLOWED are `base_on_balls`, the same key a hitter's walks drawn
        # use. Its absence here read "Walk-prone pitching seasons" cards as showing a stat
        # pitchers don't record, which is the reverse of the truth — it is the stat the theme
        # is named after.
        "P": ("innings_pitched", "wins", "losses", "saves", "strike_outs", "earned_runs",
              "era", "whip", "base_on_balls"),
    },
    "soccer": {
        "GK": ("clean_sheets", "appearances"),
        "DF": ("clean_sheets", "appearances", "goals", "assists"),
        "FW": ("appearances", "goals", "assists"),
        "MF": ("appearances", "goals", "assists"),
    },
    # NBA, tennis and F1 are deliberately absent: their stats (PPG/RPG/APG, Wins/Titles,
    # Points/Poles) apply regardless of position, so there is nothing to slice and no
    # canonical split to draw. Absent = "every column is relevant here", not "unhandled".
}

_NFL_DL_CARD = ("sacks", "tackles_combined", "tackles_for_loss", "qb_hits")
_NFL_LB_CARD = ("tackles_combined", "sacks", "tackles_for_loss", "def_interceptions")
_NFL_DB_CARD = ("tackles_combined", "def_interceptions", "passes_defended", "forced_fumbles")

POSITION_CARD: dict[str, dict[str, tuple[str, ...]]] = {
    "nfl": {
        "QB": ("passing_yards", "passing_tds", "interceptions", "rushing_yards", "rushing_tds",
               "completions", "attempts", "completion_pct"),
        "RB": ("rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds",
               "receptions", "ypc"),
        "FB": ("rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds",
               "receptions", "ypc"),
        "WR": ("receiving_yards", "receptions", "receiving_tds"),
        "TE": ("receiving_yards", "receptions", "receiving_tds"),
        "DE": _NFL_DL_CARD, "DT": _NFL_DL_CARD, "NT": _NFL_DL_CARD, "DL": _NFL_DL_CARD,
        "OLB": _NFL_LB_CARD, "MLB": _NFL_LB_CARD, "ILB": _NFL_LB_CARD, "LB": _NFL_LB_CARD,
        "CB": _NFL_DB_CARD, "FS": _NFL_DB_CARD, "SS": _NFL_DB_CARD, "S": _NFL_DB_CARD,
        "SAF": _NFL_DB_CARD, "DB": _NFL_DB_CARD,
    },
    # The real hockey stat line: G-A-P as every scoreboard prints it, plus plus-minus for
    # defencemen, whose value a bare goal total misrepresents. Goalies get the goalie line.
    "hockey": {
        "C": ("goals", "assists", "points"),
        "L": ("goals", "assists", "points"),
        "R": ("goals", "assists", "points"),
        "D": ("goals", "assists", "points", "plus_minus"),
        "G": ("wins", "gaa", "save_pct", "shutouts"),
    },
    "baseball": {"H": ("home_runs", "rbi", "avg"), "P": ("wins", "era", "strike_outs")},
    # Soccer's whole vocabulary is four keys (appearances/goals/assists/clean_sheets), so a
    # keeper's honest card is two tiles. Two real numbers beat four with "Goals 0 · Assists 0"
    # padding them out.
    "soccer": {
        "GK": ("clean_sheets", "appearances"),
        "DF": ("clean_sheets", "appearances", "goals", "assists"),
        "FW": ("goals", "assists", "appearances"),
        "MF": ("goals", "assists", "appearances"),
    },
}

# Single-game overrides for POSITION_CARD, mirroring `Sport.positionStatTemplatesGame`. NFL
# and soccer game rows carry the same stat KEYS as their season rows (a game's
# `rushing_yards` is the season field with a smaller number) so they need no entry. NBA and
# baseball differ: NBA season rows carry per-game rates (`ppg`) where game rows carry raw
# totals (`points`), and baseball game rows omit the season-only rate stats `avg`/`era`.
POSITION_CARD_GAME: dict[str, dict[str, tuple[str, ...]]] = {
    "baseball": {"H": ("home_runs", "rbi", "hits"),
                 "P": ("strike_outs", "earned_runs", "innings_pitched")},
}

# Label + format for a canonical-card stat the theme itself doesn't declare — needed only
# for FILLED-IN columns, since a stat the theme names keeps that theme's own label/fmt (and
# so its grain-correct formatting: `nfl-career-fantasy` prints career yards `comma_int`).
# `comma_int` wherever a career total can pass four digits; it renders identically to `int`
# below 1,000, so a season card is unaffected. Mirrors `ScoringStat.catalog`'s labels.
_FILL_COLUMNS: dict[str, dict[str, StatColumn]] = {
    "nfl": {c.stat: c for c in (
        StatColumn("passing_yards", "Pass Yds", "comma_int"),
        StatColumn("passing_tds", "Pass TD", "int"),
        StatColumn("interceptions", "INT", "int"),
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
        StatColumn("receiving_yards", "Rec Yds", "comma_int"),
        StatColumn("receiving_tds", "Rec TD", "int"),
        StatColumn("receptions", "Rec", "comma_int"),
        StatColumn("completions", "Cmp", "comma_int"),
        StatColumn("attempts", "Att", "comma_int"),
        StatColumn("completion_pct", "Cmp%", "dec1"),
        StatColumn("ypc", "Yds/Carry", "dec1"),
        # Defensive keys match nfl_nflverse_defense.py's vocabulary — `def_interceptions`,
        # never `interceptions`, which on an offensive row means "thrown by a QB".
        StatColumn("sacks", "Sacks", "int"),
        StatColumn("tackles_combined", "Tackles", "comma_int"),
        StatColumn("tackles_for_loss", "TFL", "int"),
        StatColumn("qb_hits", "QB Hits", "int"),
        StatColumn("def_interceptions", "Def INT", "int"),
        StatColumn("passes_defended", "PD", "int"),
        StatColumn("forced_fumbles", "FF", "int"),
    )},
    "hockey": {c.stat: c for c in (
        StatColumn("goals", "G", "int"), StatColumn("assists", "A", "int"),
        StatColumn("points", "PTS", "int"), StatColumn("plus_minus", "+/-", "int"),
        StatColumn("wins", "W", "int"), StatColumn("gaa", "GAA", "dec2"),
        StatColumn("save_pct", "SV%", "dec3"), StatColumn("shutouts", "SO", "int"),
    )},
    "baseball": {c.stat: c for c in (
        StatColumn("home_runs", "HR", "comma_int"), StatColumn("rbi", "RBI", "comma_int"),
        StatColumn("avg", "AVG", "dec3"), StatColumn("hits", "Hits", "comma_int"),
        StatColumn("wins", "W", "int"), StatColumn("era", "ERA", "dec2"),
        StatColumn("strike_outs", "K", "comma_int"),
        StatColumn("earned_runs", "ER", "int"),
        StatColumn("innings_pitched", "IP", "dec1"),
    )},
    "soccer": {c.stat: c for c in (
        StatColumn("goals", "Goals", "int"), StatColumn("assists", "Assists", "int"),
        StatColumn("appearances", "Apps", "int"),
        StatColumn("clean_sheets", "Clean Sheets", "int"),
    )},
}

# The card layout is built for four or five tiles (see Keep4CardView.statRows, which balances
# 5 → 3+2 and 4 → 2+2); past that the numbers shrink and the sheet reads as a table.
_MAX_CARD_COLUMNS = 5


def produces(sport: str, position: str | None, stat: str) -> bool:
    """Whether `position` in `sport` records `stat` at all. True when the sport/position has
    no family entry — absence means "no split to draw here", not "unknown"."""
    families = POSITION_STAT_FAMILIES.get(sport, {}).get(position or "")
    return True if families is None else stat.startswith(families)


def columns_for(theme: Theme, position: str | None = None) -> list[StatColumn]:
    """The card columns for a season at `position`.

    Single-position(-family) themes use the theme's columns as-is — they were curated for
    exactly one stat vocabulary, and a WR theme showing Yds/Rec and Targets is the point. So
    does a cross-position theme whose every column this position DOES produce: a hockey board
    mixing C/L/R is nominally cross-position but the three skater codes record the same
    things, and "Modern snipers" showing G/SOG/S%/PTS instead of the canonical G-A-P is that
    theme choosing its own emphasis, not a defect to correct.

    Otherwise — the theme names a stat this position cannot produce — the card is composed
    from the position's canonical stat card (POSITION_CARD) and filled in, so every tile is a
    stat that position actually records:

      1. the canonical keys, in canonical order, each rendered with the theme's own column
         when the theme declares it (keeping that theme's label/fmt) and `_FILL_COLUMNS`
         otherwise — this is the "fill in the canonical card" step;
      2. then any *other* theme column the position does produce, so a theme still shows the
         stat it is named after (a generated "20-20 club" board promotes SB to its columns,
         and that promotion survives).

    The whole thing is capped at `_MAX_CARD_COLUMNS`, which the canonical card takes first:
    a position whose canonical card is already that long (NFL QB) has no room for the tail.
    That is the right precedence — the canonical line is what the player reads the card by —
    but it does mean a promoted column can be crowded out on those positions.

    There is deliberately no fall-back-to-everything branch. The old one existed because
    filtering could leave too few columns; composing from the canonical card cannot, and the
    fallback is what put four zeroed passing/rushing tiles on a Travis Kelce card.
    """
    if position is None or len(theme.positions) <= 1:
        return theme.columns
    if all(produces(theme.sport, position, c.stat) for c in theme.columns):
        return theme.columns
    game = POSITION_CARD_GAME.get(theme.sport, {}).get(position) if theme.grain == "game" else None
    canonical = game or POSITION_CARD.get(theme.sport, {}).get(position)
    if canonical is None:                     # NBA/tennis/F1, or a position with no card
        return theme.columns
    declared = {c.stat: c for c in theme.columns}
    fill = _FILL_COLUMNS.get(theme.sport, {})
    out = [declared.get(k) or fill[k] for k in canonical if k in declared or k in fill]
    seen = {c.stat for c in out}
    out += [c for c in theme.columns
            if c.stat not in seen and produces(theme.sport, position, c.stat)]
    return out[:_MAX_CARD_COLUMNS] if out else theme.columns


def format_columns(theme: Theme, stats: dict[str, float],
                   position: str | None = None) -> list[dict[str, str]]:
    """Build the camelCase `stats` array for a PlayerSeason card (position-aware for
    cross-position themes — see `columns_for`)."""
    return [
        {"label": col.label, "value": fmt_value(stats.get(col.stat, 0.0), col.fmt)}
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


# ── Adding or removing a theme? Four things mirror this list, and only one is automatic ──
#
# A theme edit is a cross-language change. Python-only verification passes while the Swift
# side goes red, which is exactly what happened on 2026-09-05 when `hockey-scoring-forwards-era`
# was added: `pytest` stayed green and two Swift tests broke.
#
#   1. `BallIQ/Data/keep4_themes.json` — REGENERATE with
#      `python -m tools.ingest.main --write-themes`. Do not hand-edit. A pure function of this
#      list, and `test_bundled_themes_match_catalog` fails if it drifts.
#   2. `BallIQTests/Keep4ThemeTests.swift` — hardcodes the total theme COUNT, and asserts the
#      exact set of `eraAdjusted` theme keys.
#   3. `tools/ingest/tests/test_export_themes.py` — `app_presets` lists every scale the Swift
#      `ScoringRule.presets` mirrors; a theme on a NEW scale needs the scale added there AND
#      a matching preset in `BallIQ/Models/ScoringRule.swift`.
#   4. `tools/ingest/tests/test_no_em_dashes.py` — theme TITLES may not contain em/en dashes.
#
# So: run BOTH suites after a theme change, not just pytest.

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
            StatColumn("receiving_tds", "Rec TD", "int"),
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
        title="All-time fantasy seasons, any position",
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
        title="Best seasons of all time, era-adjusted",
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
            StatColumn("receiving_tds", "Rec TD", "int"),
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
    # ── Soccer (live since the 38-league catalog landed: transfermarkt + espn sweeps,
    # ~78k season rows; the old "seed-only" note is history). League-cohort themes are
    # only viable where `league` meta is dense (espn-sourced MLS today) — the
    # transfermarkt bulk carries no league label, so the other cohorts are stat-based. ──
    Theme(
        key="soccer-goal-machines",
        title="20-goal seasons",
        sport="soccer",
        scale="soccer_attacker_fantasy",
        positions=frozenset({"FW", "MF"}),
        min_stats={"goals": 20},
        columns=[
            StatColumn("goals", "Goals", "int"),
            StatColumn("assists", "Assists", "int"),
            StatColumn("appearances", "Apps", "int"),
        ],
    ),
    Theme(
        key="soccer-playmakers",
        title="Elite playmaker seasons",
        sport="soccer",
        scale="soccer_attacker_fantasy",
        positions=frozenset({"FW", "MF"}),
        min_stats={"assists": 10, "appearances": 15},
        columns=[
            StatColumn("assists", "Assists", "int"),
            StatColumn("goals", "Goals", "int"),
            StatColumn("appearances", "Apps", "int"),
        ],
    ),
    Theme(
        key="soccer-iron-men",
        title="Every-week iron man seasons",
        sport="soccer",
        scale="soccer_defender_fantasy",
        positions=frozenset({"DF", "GK"}),
        min_stats={"appearances": 35},
        columns=[
            StatColumn("appearances", "Apps", "int"),
            StatColumn("clean_sheets", "Clean Sheets", "int"),
            StatColumn("goals", "Goals", "int"),
        ],
    ),
    Theme(
        key="soccer-mls",
        title="MLS standout seasons",
        sport="soccer",
        scale="soccer_attacker_fantasy",
        positions=frozenset({"FW", "MF"}),
        min_stats={"appearances": 15},
        filters=(Filter(field="league", op="eq", value="USA (MLS)"),),
        columns=[
            StatColumn("goals", "Goals", "int"),
            StatColumn("assists", "Assists", "int"),
            StatColumn("appearances", "Apps", "int"),
        ],
    ),
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
    # ── Tennis (live since the WTA/ATP match sweeps: ~8.5k season rows spanning the
    # 1960s-2020s; the old "seed-only" note is history). Era slices + a country cohort,
    # per the audit's depth ask — every cohort below clears 250+ qualifying rows. ──
    Theme(
        key="tennis-wood-era",
        title="Wood-to-graphite era seasons (70s-80s)",
        sport="tennis",
        scale="tennis_fantasy",
        positions=frozenset({"Player"}),
        min_stats={"matches_won": 30},
        filters=(Filter(field="decade", op="in", value=(1970, 1980)),),
        columns=[
            StatColumn("matches_won", "Wins", "int"),
            StatColumn("titles", "Titles", "int"),
            StatColumn("grand_slams", "Slams", "int"),
            StatColumn("matches_lost", "Losses", "int"),
        ],
    ),
    Theme(
        key="tennis-golden-90s-00s",
        title="Golden-era seasons (90s-2000s)",
        sport="tennis",
        scale="tennis_fantasy",
        positions=frozenset({"Player"}),
        min_stats={"matches_won": 35},
        filters=(Filter(field="season_year", op="range", value=(1990, 2009)),),
        columns=[
            StatColumn("matches_won", "Wins", "int"),
            StatColumn("titles", "Titles", "int"),
            StatColumn("grand_slams", "Slams", "int"),
            StatColumn("matches_lost", "Losses", "int"),
        ],
    ),
    Theme(
        key="tennis-modern",
        title="Modern-era tour seasons (2010s+)",
        sport="tennis",
        scale="tennis_fantasy",
        positions=frozenset({"Player"}),
        min_stats={"matches_won": 30},
        filters=(Filter(field="season_year", op="gte", value=2010),),
        columns=[
            StatColumn("matches_won", "Wins", "int"),
            StatColumn("titles", "Titles", "int"),
            StatColumn("grand_slams", "Slams", "int"),
            StatColumn("matches_lost", "Losses", "int"),
        ],
    ),
    Theme(
        key="tennis-usa",
        title="American tennis seasons",
        sport="tennis",
        scale="tennis_fantasy",
        positions=frozenset({"Player"}),
        min_stats={"matches_won": 25},
        filters=(Filter(field="team", op="eq", value="USA"),),
        columns=[
            StatColumn("matches_won", "Wins", "int"),
            StatColumn("titles", "Titles", "int"),
            StatColumn("grand_slams", "Slams", "int"),
            StatColumn("matches_lost", "Losses", "int"),
        ],
    ),
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

    # -- Hockey (M31, live via providers/nhl_stats.py: full-league seasons 1917-18 onward,
    # the deepest history in the catalog). Skaters and goalies are graded by two different
    # scales because they share no stat key, exactly like baseball's hitter/pitcher split,
    # and every theme is single-role for that reason -- a mixed board would have to show one
    # of them a stat family it does not record. Era slices use `decade`/`season_year` rather
    # than raw totals because scoring levels swing enormously across NHL history (a 100-point
    # season in the clutch-and-grab late 90s is not a 100-point season in 1985). --
    Theme(
        key="hockey-scoring-forwards",
        title="Elite forward scoring seasons",
        sport="hockey",
        scale="hockey_skater_fantasy",
        positions=frozenset({"C", "L", "R"}),
        min_stats={"points": 70, "games": 60},
        columns=[
            StatColumn("goals", "G", "int"),
            StatColumn("assists", "A", "int"),
            StatColumn("points", "PTS", "int"),
            StatColumn("plus_minus", "+/-", "int"),
            StatColumn("shots", "SOG", "int"),
        ],
    ),
    Theme(
        key="hockey-blueliners",
        title="Big offensive seasons from the blue line",
        sport="hockey",
        scale="hockey_skater_fantasy",
        positions=frozenset({"D"}),
        min_stats={"points": 40, "games": 60},
        columns=[
            StatColumn("points", "PTS", "int"),
            StatColumn("goals", "G", "int"),
            StatColumn("assists", "A", "int"),
            StatColumn("plus_minus", "+/-", "int"),
            StatColumn("penalty_minutes", "PIM", "int"),
        ],
    ),
    Theme(
        key="hockey-goalies",
        title="Great goaltending seasons",
        sport="hockey",
        scale="hockey_goalie_fantasy",
        positions=frozenset({"G"}),
        # A save-percentage floor rather than a wins floor: wins are a team stat, and a
        # wins-only gate would fill the board with average goalies on great teams.
        min_stats={"wins": 20, "save_pct": 0.900, "games": 30},
        columns=[
            StatColumn("wins", "W", "int"),
            StatColumn("save_pct", "SV%", "dec3"),
            StatColumn("gaa", "GAA", "dec2"),
            StatColumn("shutouts", "SO", "int"),
            StatColumn("saves", "SV", "comma_int"),
        ],
    ),
    Theme(
        key="hockey-eighties-offense",
        title="Run-and-gun 80s scoring seasons",
        sport="hockey",
        scale="hockey_skater_fantasy",
        positions=frozenset({"C", "L", "R"}),
        min_stats={"points": 80, "games": 60},
        filters=(Filter(field="decade", op="in", value=(1980,)),),
        columns=[
            StatColumn("goals", "G", "int"),
            StatColumn("assists", "A", "int"),
            StatColumn("points", "PTS", "int"),
            StatColumn("pp_points", "PPP", "int"),
        ],
    ),
    Theme(
        key="hockey-modern-snipers",
        title="Modern-era goal scorers (2010s+)",
        sport="hockey",
        scale="hockey_skater_fantasy",
        positions=frozenset({"C", "L", "R"}),
        min_stats={"goals": 25, "games": 60},
        filters=(Filter(field="season_year", op="gte", value=2010),),
        columns=[
            StatColumn("goals", "G", "int"),
            StatColumn("shots", "SOG", "int"),
            StatColumn("shooting_pct", "S%", "pct1"),
            StatColumn("points", "PTS", "int"),
        ],
    ),
    Theme(
        key="hockey-scoring-forwards-era",
        title="Elite forward scoring seasons, era-adjusted",
        sport="hockey",
        scale="hockey_skater_fantasy",
        era_adjusted=True,
        # Same pool as hockey-scoring-forwards, but graded by raw PPR-style points × the
        # per-(position, year) volume index (baselines.py now emits `fantasy_total` for
        # hockey — see that module's QUALIFY/TOTAL_SCALE). Without this, the raw-points
        # version of this theme comes out 5-of-8 from the 1980s (Gretzky '81, Lemieux '88,
        # Bossy '81, Nicholls '88, Yzerman '88) purely because 1980s scoring totals are
        # bigger numbers, not because those seasons were more dominant relative to their
        # own league that year. Era-adjusting spreads the same pool across five different
        # decades (1970s/80s/90s/2000s/2020s) instead of one, and still surfaces McDavid,
        # Jagr and MacKinnon alongside Gretzky rather than burying them under raw volume.
        positions=frozenset({"C", "L", "R"}),
        min_stats={"points": 70, "games": 60},
        columns=[
            StatColumn("goals", "G", "int"),
            StatColumn("assists", "A", "int"),
            StatColumn("points", "PTS", "int"),
            StatColumn("plus_minus", "+/-", "int"),
            StatColumn("shots", "SOG", "int"),
        ],
    ),

    # -- F1 (M31, live via providers/f1_ergast.py: driver-seasons 1950-present). Columns
    # deliberately never include championship points: F1 rewrote its points system in 1961,
    # 1991 and 2010, so the column would compare 1954 to 2024 on a scale that changed by 3x
    # underneath it. See grade.py's `f1_driver_fantasy`. `fastest_laps` is absent from
    # pre-2004 rows (Ergast has no such data), so it is only a column on the modern theme. --
    Theme(
        key="f1-title-fights",
        title="Championship-contending driver seasons",
        sport="f1",
        scale="f1_driver_fantasy",
        positions=frozenset({"Driver"}),
        min_stats={"podiums": 4, "races": 8},
        columns=[
            StatColumn("wins", "Wins", "int"),
            StatColumn("podiums", "Podiums", "int"),
            StatColumn("poles", "Poles", "int"),
            StatColumn("races", "Starts", "int"),
        ],
    ),
    Theme(
        key="f1-race-winners",
        title="Race-winning seasons",
        sport="f1",
        scale="f1_driver_fantasy",
        positions=frozenset({"Driver"}),
        min_stats={"wins": 1, "races": 6},
        columns=[
            StatColumn("wins", "Wins", "int"),
            StatColumn("podiums", "Podiums", "int"),
            StatColumn("poles", "Poles", "int"),
            StatColumn("dnfs", "DNFs", "int"),
        ],
    ),
    Theme(
        key="f1-modern-era",
        title="Modern-era driver seasons (2010s+)",
        sport="f1",
        scale="f1_driver_fantasy",
        positions=frozenset({"Driver"}),
        min_stats={"top_tens": 5, "races": 10},
        filters=(Filter(field="season_year", op="gte", value=2010),),
        columns=[
            StatColumn("podiums", "Podiums", "int"),
            StatColumn("top_tens", "Top 10s", "int"),
            StatColumn("poles", "Poles", "int"),
            StatColumn("fastest_laps", "FL", "int"),
        ],
    ),
]
