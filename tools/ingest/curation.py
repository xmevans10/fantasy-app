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
    # Per-position weight-class thresholds (lbs) for the lightweight/heavyweight quirks below.
    # Skill positions run lighter than the NFL average, so a single league-wide cutoff would
    # under/over-select by position; QB is heavier-leaning than WR/TE at both ends.
    light_lb: float = 200
    heavy_lb: float = 230


POSITIONS: dict[str, PositionSpec] = {
    "WR": PositionSpec("WR", "WR", "nfl_skill_ppr", {"receiving_yards": 600}, _WR_TE_COLS,
                        light_lb=190, heavy_lb=225),
    "TE": PositionSpec("TE", "TE", "nfl_skill_ppr", {"receiving_yards": 400}, _WR_TE_COLS,
                        light_lb=230, heavy_lb=260),
    "RB": PositionSpec("RB", "RB", "nfl_skill_ppr", {"rushing_yards": 600}, [
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
        StatColumn("ypc", "Yds/Carry", "dec1"),
        StatColumn("receptions", "Rec", "int"),
        StatColumn("receiving_yards", "Rec Yds", "comma_int"),
    ], light_lb=200, heavy_lb=230),
    "QB": PositionSpec("QB", "QB", "nfl_qb_fantasy", {"passing_yards": 2000}, [
        StatColumn("passing_yards", "Pass Yds", "comma_int"),
        StatColumn("passing_tds", "Pass TD", "int"),
        StatColumn("interceptions", "INT", "int"),
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
    ], light_lb=210, heavy_lb=245),
}

# Decades to slice (nflverse season data is 1999+, so no full 1990s). `None` = all-time.
DECADES: list[int | None] = [None, 2000, 2010, 2020]


@dataclass(frozen=True)
class Quirk:
    key: str
    filters: tuple[Filter, ...]
    # title takes the position label, returns the theme title (decade prefix added separately).
    title: str               # uses "{pos}" placeholder
    # Short lowercase fragment used to build a combo title when two quirks are ANDed together
    # (see generate.py's pairwise combos), e.g. "undrafted" + "sub-6-foot" ->
    # "Undrafted, sub-6-foot {pos} seasons". Defaults to `key` when the key already reads as
    # a fragment; spelled out explicitly below wherever the key is terser than its title.
    adjective: str = ""

    def __post_init__(self) -> None:
        if not self.adjective:
            object.__setattr__(self, "adjective", self.key)


# Weight-class quirks are position-relative (a "light" QB and a "light" WR are different
# numbers — see `PositionSpec.light_lb`/`heavy_lb` above), so they can't carry a fixed Filter
# value the way height/age do. Left with empty placeholder filters here; `weight_filters()`
# below builds the real per-position Filter, and generate.py substitutes it in when it knows
# which PositionSpec a candidate is for.
_WEIGHT_QUIRKS: list["Quirk"] = [
    Quirk("lightweight", (), "Lightweight {pos} seasons", adjective="lightweight"),
    Quirk("heavyweight", (), "Bruiser {pos} seasons", adjective="bruiser"),
]


def weight_filters(spec: PositionSpec) -> dict[str, tuple[Filter, ...]]:
    """The real, position-relative filters for the weight-class quirks above."""
    return {
        "lightweight": (Filter("weight_lb", "lte", spec.light_lb),),
        "heavyweight": (Filter("weight_lb", "gte", spec.heavy_lb),),
    }


QUIRKS: list[Quirk] = [
    Quirk("undrafted", (Filter("draft_round", "exists", False),), "Undrafted {pos} gems",
          adjective="undrafted"),
    Quirk("day2", (Filter("draft_round", "in", [2, 3, 4]),), "Day-2 {pos} finds (rounds 2–4)",
          adjective="Day-2"),
    Quirk("day3", (Filter("draft_round", "gte", 5),), "Day-3 {pos} steals (round 5+)",
          adjective="Day-3"),
    Quirk("first-round", (Filter("draft_round", "eq", 1),), "First-round {pos} seasons",
          adjective="first-round"),
    Quirk("top10-pick", (Filter("draft_pick", "lte", 10),), "Top-10-pick {pos} phenoms",
          adjective="top-10-pick"),
    Quirk("mr-irrelevant", (Filter("draft_pick", "gte", 200),), "Late-round-flier {pos} seasons",
          adjective="late-round-flier"),
    Quirk("sub6", (Filter("height_in", "lte", 71),), "Sub-6-foot {pos} seasons",
          adjective="sub-6-foot"),
    Quirk("towering", (Filter("height_in", "gte", 77),), "Towering (6'5\"+) {pos} seasons",
          adjective="towering"),
    *_WEIGHT_QUIRKS,
    Quirk("young", (Filter("age", "lte", 23),), "Under-24 {pos} seasons", adjective="under-24"),
    Quirk("prime", (Filter("age", "range", (27, 30)),), "Prime-years (27–30) {pos} seasons",
          adjective="prime-years"),
    Quirk("vet", (Filter("age", "gte", 33),), "Age-33+ {pos} seasons", adjective="age-33+"),
    Quirk("ancient", (Filter("age", "gte", 36),), "Ageless-wonder {pos} seasons (36+)",
          adjective="ageless-wonder"),
    Quirk("rookie-year", (Filter("is_rookie_season", "eq", True),), "Rookie-season {pos} breakouts",
          adjective="rookie-season"),
]

# Quirk pairs that are structurally redundant or contradictory to combine (the viability gate
# already drops empty/unfair pools, so this is just to skip obviously wasted work, not a
# correctness requirement). E.g. combining two age bands or two draft-pedigree bands narrows
# to a sub-slice of a single dimension rather than a genuinely two-dimensional niche.
_AGE_KEYS = {"young", "prime", "vet", "ancient"}
_DRAFT_KEYS = {"undrafted", "day2", "day3", "first-round", "top10-pick", "mr-irrelevant"}
_SIZE_KEYS = {"sub6", "towering", "lightweight", "heavyweight"}


def redundant_pair(a: "Quirk", b: "Quirk") -> bool:
    for group in (_AGE_KEYS, _DRAFT_KEYS, _SIZE_KEYS):
        if a.key in group and b.key in group:
            return True
    return False

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
