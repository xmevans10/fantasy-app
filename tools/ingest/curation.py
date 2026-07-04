"""Editorial config for the niche-theme generator (see generate.py).

This is the "what/how it's framed" half: which positions, eras, bio-quirks and first
names to try, how to title them, what to forbid, and how many to keep. The generator
(`generate.py`) is the "is it a fair puzzle" half — it builds each candidate and keeps
only the ones with 8 close, recognizable seasons and a clean keep/cut boundary.
"""
from __future__ import annotations

from dataclasses import dataclass

from .themes import Filter, StatColumn

# Per-position grade scale, inclusion floor, and on-card stat columns (mirrors the curated
# themes' look). The floor only strips scrubs; eliteness comes from grading + pool_cap.
_WR_TE_COLS = [
    StatColumn("receiving_yards", "Rec Yds", "comma_int"),
    StatColumn("receptions", "Rec", "int"),
    StatColumn("receiving_tds", "Rec TD", "int"),
    StatColumn("ypr", "Yds/Rec", "dec1"),
    StatColumn("targets", "Tgts", "int"),
]


@dataclass(frozen=True)
class PositionSpec:
    pos: str
    label: str
    scale: str
    min_stats: dict[str, float]
    columns: list[StatColumn]


POSITIONS: dict[str, PositionSpec] = {
    "WR": PositionSpec("WR", "WR", "nfl_skill_ppr", {"receiving_yards": 600}, _WR_TE_COLS),
    "TE": PositionSpec("TE", "TE", "nfl_skill_ppr", {"receiving_yards": 400}, _WR_TE_COLS),
    "RB": PositionSpec("RB", "RB", "nfl_skill_ppr", {"rushing_yards": 600}, [
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
        StatColumn("ypc", "Yds/Carry", "dec1"),
        StatColumn("receptions", "Rec", "int"),
        StatColumn("receiving_yards", "Rec Yds", "comma_int"),
    ]),
    "QB": PositionSpec("QB", "QB", "nfl_qb_fantasy", {"passing_yards": 2000}, [
        StatColumn("passing_yards", "Pass Yds", "comma_int"),
        StatColumn("passing_tds", "Pass TD", "int"),
        StatColumn("interceptions", "INT", "int"),
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
    ]),
}

# Decades to slice (nflverse season data is 1999+, so no full 1990s). `None` = all-time.
DECADES: list[int | None] = [None, 2000, 2010, 2020]


@dataclass(frozen=True)
class Quirk:
    key: str
    filters: tuple[Filter, ...]
    # title takes the position label, returns the theme title (decade prefix added separately).
    title: str               # uses "{pos}" placeholder


QUIRKS: list[Quirk] = [
    Quirk("undrafted", (Filter("draft_round", "exists", False),), "Undrafted {pos} gems"),
    Quirk("day3", (Filter("draft_round", "gte", 5),), "Day-3 {pos} steals (round 5+)"),
    Quirk("first-round", (Filter("draft_round", "eq", 1),), "First-round {pos} seasons"),
    Quirk("sub6", (Filter("height_in", "lte", 71),), "Sub-6-foot {pos} seasons"),
    Quirk("towering", (Filter("height_in", "gte", 77),), "Towering (6'5\"+) {pos} seasons"),
    Quirk("vet", (Filter("age", "gte", 33),), "Age-33+ {pos} seasons"),
    Quirk("young", (Filter("age", "lte", 23),), "Under-24 {pos} seasons"),
]

# First-name themes are the signature niche hook ("a guy named Mike"). Keyed by the display
# first name → the set of roster spellings that count (nicknames: Mike∪Michael), matched
# case-insensitively as `^(mike|michael)$`. Name themes run ALL-TIME only (a single name
# rarely fields 8 close stars within one decade). The viability gate drops the rest.
NAME_VARIANTS: dict[str, list[str]] = {
    "Mike": ["mike", "michael"],
    "Chris": ["chris", "christopher"],
    "Joe": ["joe", "joseph"],
    "Tom": ["tom", "thomas"],
    "Matt": ["matt", "matthew"],
    "Tony": ["tony", "anthony"],
    "Rob": ["rob", "robert", "bobby"],
    "Will": ["will", "william"],
    "Cam": ["cam", "cameron"],
    "Drew": ["drew"],
    "Aaron": ["aaron"],
    "Josh": ["josh", "joshua"],
    "Marcus": ["marcus"],
    "Antonio": ["antonio"],
    "David": ["david", "dave"],
    "Steve": ["steve", "steven", "stephen"],
}


def name_regex(variants: list[str]) -> str:
    return "^(" + "|".join(variants) + ")$"

# Combos to never publish even if viable (awkward/misleading framing).
DENYLIST: set[str] = set()

# How many generated themes to keep per run, and the per-position cap so one position
# can't dominate the archive. Deterministic selection keeps daily archives reproducible.
MAX_GENERATED = 16
PER_POSITION_CAP = 5
# A card is "recognizable" if it has a headshot; require this many of 8 so puzzles are
# real stars, not obscure names dug up by an over-niche filter.
MIN_RECOGNIZABLE = 6


def decade_prefix(decade: int | None) -> str:
    return f"{decade}s " if decade is not None else ""


def name_title(spec: PositionSpec, first: str) -> str:
    return f"{spec.label} seasons by a guy named {first}"
