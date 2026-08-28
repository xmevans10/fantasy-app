"""Editorial config for the niche-theme generator (see generate.py).

This is the "what/how it's framed" half: which positions, eras, bio-quirks and first
names to try, how to title them, what to forbid, and how many to keep. The generator
(`generate.py`) is the "is it a fair puzzle" half — it builds each candidate and keeps
only the ones with 8 close, recognizable seasons and a clean keep/cut boundary.
"""
from __future__ import annotations

import dataclasses
from dataclasses import dataclass

from .models import slug
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
    # The roster positions this spec actually selects. NFL specs are one position each, so
    # `pos` IS the set; every other sport groups several ("bigs" = F+C, soccer's back line =
    # DF+GK), which the curated themes already do via `Theme.positions`. Empty = just `pos`.
    members: tuple[str, ...] = ()
    # Grain and pool cap mirror `Theme`'s, so a sport can generate career- or game-grain
    # niches (baseball's single-game outbursts, NBA's career aggregates) rather than only
    # season ones. Defaults match `Theme`'s own defaults.
    grain: str = "season"
    pool_cap: int = 24

    @property
    def position_set(self) -> frozenset[str]:
        return frozenset(self.members or (self.pos,))


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
    # Cross-positional, SEASON grain. One unified PPR formula judges every skill position on
    # the same axis. This existed only as two hand-written curated themes (`nfl-total-fantasy`
    # and its era-adjusted twin) and was unreachable by the generator, because no spec grouped
    # the positions under one scale, so the single commonest shape in the reference catalogue
    # could never be rolled with an era, a division or a club attached.
    #
    # `min_stats` must stay position-neutral: entries are ANDed, so a `receiving_yards` floor
    # would silently exclude every quarterback. Gate on games played, exactly as the curated
    # theme documents.
    "ANY": PositionSpec("ANY", "player", "nfl_fantasy", {"games": 8}, [
        StatColumn("passing_yards", "Pass Yds", "comma_int"),
        StatColumn("passing_tds", "Pass TD", "int"),
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
        StatColumn("receptions", "Rec", "int"),
        StatColumn("receiving_yards", "Rec Yds", "comma_int"),
        StatColumn("receiving_tds", "Rec TD", "int"),
    ], members=("QB", "RB", "WR", "TE")),
}

# Decades to slice (nflverse season data is 1999+, so no full 1990s). `None` = all-time.
DECADES: list[int | None] = [None, 2000, 2010, 2020]


# Quirk families. Declared ABOVE `Quirk` because `_infer_group` runs inside `__post_init__`,
# i.e. while the quirk lists further down are still being constructed. `redundant_pair` reads
# the same three sets, so a quirk's family and its "these two are structurally redundant
# together" grouping can never drift apart.
_AGE_KEYS = {"young", "prime", "vet", "ancient"}
_DRAFT_KEYS = {"undrafted", "day2", "day3", "first-round", "top10-pick", "mr-irrelevant"}
_SIZE_KEYS = {"sub6", "towering", "lightweight", "heavyweight"}


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

    # Which single dimension this quirk slices. Two quirks sharing a non-empty axis are
    # structurally redundant to AND together (two age bands, two draft bands, two flavors of
    # "he hit for power") and `redundant_pair` skips the combo. NFL's quirks predate this
    # field and are still grouped by the legacy key sets below, so both mechanisms are live.
    axis: str = ""
    # Stat columns this quirk is *about*, promoted to the front of the card so a puzzle
    # titled "20-20 club seasons" actually shows HR and SB. Empty = leave the position
    # spec's columns alone (every NFL quirk is a bio filter, so none of them set this).
    columns: tuple[StatColumn, ...] = ()
    # Which FAMILY of hook this is, for draw weighting (see `QUIRK_GROUP_SHARE` and
    # `generate.roll_spec`). Empty falls back to "other".
    #
    # This exists because inventory share and OUTPUT share are not the same number. Draft
    # quirks are 6 of NFL's 25 (24%), but a replay of the 2024 season minted a draft-themed
    # board in 8 of 18 weeks (44%): at game grain most of the STAT quirks fail viability (a
    # "300-carry" threshold cannot be met in one game), so the survivors skew hard to
    # biographical hooks and draft is the biggest bio family. Uniform sampling over whatever
    # happens to be viable is what produced a season that read like a scouting report.
    group: str = ""
    # PositionSpec keys this quirk is allowed to pair with. Empty = every cohort in the sport.
    #
    # Some archetypes only mean something for one cohort. "Goal-scoring" is a genuine oddity
    # for a centre-back and a tautology for a striker — crossed with the forward spec it
    # produced the theme "Goal-scoring forward seasons", whose filter (7+ goals) every card in
    # the pool already cleared. Contrast the NBA, where the cross-products are the *point*: a
    # guard pulling twelve rebounds, or a big man handing out eight assists, is exactly the
    # kind of board worth building, so those quirks stay unrestricted.
    only: tuple[str, ...] = ()

    def applies_to(self, spec_key: str) -> bool:
        return not self.only or spec_key in self.only

    def __post_init__(self) -> None:
        if not self.adjective:
            object.__setattr__(self, "adjective", self.key)
        if not self.group:
            object.__setattr__(self, "group", _infer_group(self.key, self.axis))


# Target share of ROLLS each quirk family gets, independent of how many quirks it happens to
# contain. Families not named here split the remainder evenly.
#
# `draft` is pinned at 0.10 on a product call: a draft round is a fun hook a couple of times a
# season and tiresome as a weekly identity. BallGame (ballgamehq.com, the closest comparable
# Keep4/Cut4 daily) treats the draft the same way, as a themed WEEK ("NFL DRAFT WEEK") rather
# than a recurring per-puzzle filter, and leads its everyday titles with the stat instead
# ("2010s: Top Rookie Receiving TD Seasons").
QUIRK_GROUP_SHARE: dict[str, float] = {
    "draft": 0.10,
    "size":  0.12,
    "age":   0.15,
}

# ── Slice axes the reference catalogue leans on that we had no support for ────────
#
# Measured against 38 real BallGame Pod "Keep 4, Cut 4" titles:
#   50%  position only, NO qualifying hook at all ("NFL Cornerbacks", "All-Time Running Backs")
#   21%  a DIVISION or conference ("All-Time AFC East Seasons") -- eight of the thirty-eight
#   29%  use "All-Time" as the era word, 8% "Active", only 5% a decade
#    3%  a draft pick, once, across the whole sample
#   every single title carries either zero or one qualifier. Never two.
#
# Our roller was doing close to the opposite: always a quirk, two of them 45% of the time,
# decades as the only era vocabulary, and no way to say "AFC East" at all.

NFL_DIVISIONS: dict[str, tuple[str, ...]] = {
    "AFC East":  ("BUF", "MIA", "NE", "NYJ"),
    "AFC North": ("BAL", "CIN", "CLE", "PIT"),
    "AFC South": ("HOU", "IND", "JAX", "TEN"),
    "AFC West":  ("DEN", "KC", "LAC", "LV"),
    "NFC East":  ("DAL", "NYG", "PHI", "WAS"),
    "NFC North": ("CHI", "DET", "GB", "MIN"),
    "NFC South": ("ATL", "CAR", "NO", "TB"),
    "NFC West":  ("ARI", "LA", "SEA", "SF"),
}


def division_slices(divisions: dict[str, tuple[str, ...]]) -> tuple[Slice, ...]:
    """One slice per division, on its own `division` axis so the roller treats it as an
    alternative to a single club rather than something to AND with one."""
    return tuple(
        Slice(key=slug(name), filters=(Filter("team", "in", teams),),
              suffix=f", {name}", axis="division")
        for name, teams in divisions.items()
    )


def conference_slices(divisions: dict[str, tuple[str, ...]]) -> tuple[Slice, ...]:
    out = []
    for conf in ("AFC", "NFC"):
        teams = tuple(t for name, ts in divisions.items() if name.startswith(conf) for t in ts)
        out.append(Slice(key=conf.lower(), filters=(Filter("team", "in", teams),),
                         suffix=f", the {conf}", axis="division"))
    return tuple(out)


def active_slice(current_year: int, seasons_back: int = 3) -> Slice:
    """"Active" as the reference uses it: recent enough to still be playing. A rolling window
    off the current year rather than a hardcoded year, so it never goes stale."""
    return Slice(key="active",
                 filters=(Filter("season_year", "gte", current_year - seasons_back),),
                 prefix="Active ", axis="era")

_GROUP_KEYS: dict[str, set[str]] = {}


def _infer_group(key: str, axis: str) -> str:
    """A quirk's family, derived from the legacy key sets that `redundant_pair` already uses,
    so nothing has to be relabelled by hand and the two mechanisms cannot disagree."""
    if key in _DRAFT_KEYS:
        return "draft"
    if key in _SIZE_KEYS:
        return "size"
    if key in _AGE_KEYS:
        return "age"
    return "stat" if axis else "other"


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
    Quirk("day2", (Filter("draft_round", "in", [2, 3, 4]),), "Day-2 {pos} finds (rounds 2 to 4)",
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
    Quirk("prime", (Filter("age", "range", (27, 30)),), "Prime-years (27 to 30) {pos} seasons",
          adjective="prime-years"),
    Quirk("vet", (Filter("age", "gte", 33),), "Age-33+ {pos} seasons", adjective="age-33+"),
    Quirk("ancient", (Filter("age", "gte", 36),), "Ageless-wonder {pos} seasons (36+)",
          adjective="ageless-wonder"),
    Quirk("rookie-year", (Filter("is_rookie_season", "eq", True),), "Rookie-season {pos} breakouts",
          adjective="rookie-season"),

    # ── Stat-line quirks ────────────────────────────────────────────────────────
    # Every quirk above is BIOGRAPHICAL, and bio comes from one place: `merge_nfl_bio`'s
    # join onto nflverse `players.csv` by gsis id. When that join is unavailable the entire
    # NFL quirk vocabulary filters to nothing — measured on a catalog without it, NFL rolled
    # 11 viable themes from 500 attempts while every other sport filled 60 in ~150. These are
    # written against the stat line, which is always present, so the sport degrades to a
    # smaller vocabulary instead of an empty one. They are also just more angles.
    Quirk("deep-threat", (Filter("ypr", "gte", 16.0), Filter("receptions", "gte", 40)),
          "Deep-threat {pos} seasons", adjective="deep-threat", axis="explosiveness",
          only=("WR", "TE")),
    Quirk("target-hog", (Filter("targets", "gte", 140),), "Target-hog {pos} seasons",
          adjective="target-hog", axis="usage"),
    Quirk("hands-team", (Filter("receptions", "gte", 100),), "100-catch {pos} seasons",
          adjective="100-catch", axis="usage", only=("WR", "TE", "RB")),
    Quirk("endzone", (Filter("receiving_tds", "gte", 12),), "Twelve-touchdown {pos} seasons",
          adjective="twelve-touchdown", axis="scoring", only=("WR", "TE")),
    Quirk("bellcow", (Filter("carries", "gte", 300),), "300-carry {pos} seasons",
          adjective="300-carry", axis="usage", only=("RB",)),
    Quirk("explosive-rb", (Filter("ypc", "gte", 5.0), Filter("carries", "gte", 150)),
          "Five-yards-a-carry {pos} seasons", adjective="five-a-carry", axis="explosiveness",
          only=("RB",)),
    Quirk("goal-line", (Filter("rushing_tds", "gte", 15),), "Fifteen-rushing-TD {pos} seasons",
          adjective="fifteen-rushing-TD", axis="scoring", only=("RB",)),
    Quirk("gunslinger", (Filter("passing_tds", "gte", 35),), "35-touchdown {pos} seasons",
          adjective="35-touchdown", axis="scoring", only=("QB",)),
    Quirk("pick-prone", (Filter("interceptions", "gte", 18),), "Interception-prone {pos} seasons",
          adjective="interception-prone", axis="turnovers", only=("QB",)),
    # The one every fantasy player argues about: production that came with the ball in his
    # hands on the ground as well as through the air.
    Quirk("dual-threat-stat", (Filter("passing_yards", "gte", 3500),
                               Filter("rushing_yards", "gte", 500)),
          "Pass-and-run {pos} seasons", adjective="pass-and-run", axis="profile",
          only=("QB",)),
]

# Quirk pairs that are structurally redundant or contradictory to combine (the viability gate
# already drops empty/unfair pools, so this is just to skip obviously wasted work, not a
# correctness requirement). E.g. combining two age bands or two draft-pedigree bands narrows
# to a sub-slice of a single dimension rather than a genuinely two-dimensional niche.


def redundant_pair(a: "Quirk", b: "Quirk") -> bool:
    if a.axis and a.axis == b.axis:
        return True
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


# ── Cross-sport generation ────────────────────────────────────────────────────────
#
# Everything above this line is NFL's instance of the generator config; everything below
# generalizes it so the other four sports get a real generated theme space too.
#
# Why this exists: the daily picker (`daily_puzzle.pick_novel_puzzle`) de-duplicates on the
# player-set *signature*, so it never serves the identical eight cards twice — but with only
# a handful of curated themes per sport it re-served the same THEME constantly, which is what
# a player (and the daily-drop push, which names the theme) actually notices. Measured live
# on 2026-08-18: across 24 minted days, baseball drew from 6 distinct themes and served
# "Ace pitching seasons" 9 times, while NFL — the one sport with a generated space — drew 44
# distinct themes across 45 days. The fix is more theme space, not a bigger dedupe window.
#
# The NFL quirks are all *biographical* (draft round, height, age), which only nflverse's
# players.csv supplies. No other sport has a bio provider, so their niches are built from the
# dimension every sport does carry: the stat line itself, plus era/league/country context.


@dataclass(frozen=True)
class Slice:
    """One context axis value a theme can be narrowed to — an era, a league, a nationality.

    Generalizes what `DECADES` did for NFL. `key` is the fragment that lands in the theme key
    (so it must be stable — it's half of a `puzzle_history` signature); `prefix`/`suffix`
    frame the title around the quirk's own wording.

    `axis` names the DIMENSION this slice belongs to, so the roller can pick at most one value
    per dimension (two eras ANDed is an empty pool; an era AND a club is the good stuff). The
    enumerated path ignores it and treats every slice as one flat list, exactly as before.
    """
    key: str
    filters: tuple[Filter, ...] = ()
    prefix: str = ""
    suffix: str = ""
    axis: str = "era"


def decade_slices(decades: list[int | None]) -> tuple[Slice, ...]:
    """`DECADES`-style list → slices. Reproduces the exact pre-existing NFL keys and titles
    (`gen-wr-2010-undrafted`, "2010s Undrafted WR gems"), so no NFL signature changes."""
    return tuple(
        Slice(key=str(d) if d is not None else "all",
              filters=() if d is None else (Filter("decade", "eq", d),),
              prefix=decade_prefix(d), axis="era")
        for d in decades
    )


def combine(outer: Slice, inner: Slice) -> Slice:
    """AND two slices into one — "1990s" x "NYY" -> 1990s Yankees seasons.

    Filters concatenate (they are ANDed anyway), the era keeps the prefix and the franchise
    keeps the suffix, so the title still reads as a sentence rather than a key."""
    return Slice(key=f"{outer.key}-{inner.key}",
                 filters=outer.filters + inner.filters,
                 prefix=outer.prefix or inner.prefix,
                 suffix=inner.suffix + outer.suffix,
                 axis=f"{outer.axis}+{inner.axis}")


@dataclass(frozen=True)
class SportCuration:
    """One sport's generator config: what to slice by, which cohorts, which quirks."""
    sport: str
    positions: dict[str, PositionSpec]
    quirks: list[Quirk]
    slices: tuple[Slice, ...]
    # Whether to also enumerate two-quirk combos for this sport. On everywhere; the viability
    # gate is what actually decides whether a combo survives.
    pairwise: bool = True
    # How many franchises to slice by, most-seasons-first, computed from the data at generation
    # time rather than listed here. A hardcoded roster of clubs is a literal that encodes "now"
    # (AGENTS.md §2): teams relocate, rename and get added, and the list would rot silently.
    # 0 disables the axis — tennis, where `team_abbr` is a NATIONALITY and is already sliced.
    team_slices: int = 0
    # Franchises crossed with eras ("1990s Yankees"), the most specific slice the data
    # supports. Deliberately a smaller cross than `team_slices` x every era: the product grows
    # fast and a thin cell just fails the viability gate after paying to build it.
    team_era_slices: int = 0
    team_era_decades: tuple[int, ...] = ()
    # Whether the ordinary nightly mint (daily_puzzle.build_candidates) rolls this cohort.
    # False keeps a cohort reachable by the period-scoped fresh-drop mint ONLY. The
    # game-grain cohorts are registered False on purpose: switching them on for the nightly
    # roll would roughly double its candidate space as an unmeasured side effect of shipping
    # fresh drops. Flip them on deliberately, with a measurement, not by accident.
    daily: bool = True


# ── Column sets (lifted from the curated themes so a generated card looks identical) ──
_MLB_HITTER_COLS = [
    StatColumn("home_runs", "HR", "int"),
    StatColumn("rbi", "RBI", "int"),
    StatColumn("avg", "AVG", "dec3"),
    StatColumn("ops", "OPS", "dec3"),
    StatColumn("runs", "R", "int"),
]
_MLB_PITCHER_COLS = [
    StatColumn("strike_outs", "K", "int"),
    StatColumn("wins", "W", "int"),
    StatColumn("era", "ERA", "dec2"),
    StatColumn("whip", "WHIP", "dec2"),
    StatColumn("innings_pitched", "IP", "dec1"),
]
_NBA_COLS = [
    StatColumn("ppg", "PPG", "dec1"),
    StatColumn("rpg", "RPG", "dec1"),
    StatColumn("apg", "APG", "dec1"),
    StatColumn("spg", "SPG", "dec1"),
    StatColumn("ts_pct", "TS%", "pct1"),
]
_SOCCER_ATT_COLS = [
    StatColumn("goals", "Goals", "int"),
    StatColumn("assists", "Assists", "int"),
    StatColumn("appearances", "Apps", "int"),
]
_SOCCER_DEF_COLS = [
    StatColumn("clean_sheets", "Clean Sheets", "int"),
    StatColumn("appearances", "Apps", "int"),
    StatColumn("goals", "Goals", "int"),
    StatColumn("assists", "Assists", "int"),
]
_TENNIS_COLS = [
    StatColumn("matches_won", "Wins", "int"),
    StatColumn("titles", "Titles", "int"),
    StatColumn("grand_slams", "Slams", "int"),
    StatColumn("matches_lost", "Losses", "int"),
]

# Promoted columns, so an archetype's card leads with the stat it's named after.
_SB = StatColumn("stolen_bases", "SB", "int")
_OBP = StatColumn("obp", "OBP", "dec3")
_SLG = StatColumn("slg", "SLG", "dec3")
_HITS = StatColumn("hits", "Hits", "int")
_DOUBLES = StatColumn("doubles", "2B", "int")
_TRIPLES = StatColumn("triples", "3B", "int")
_BB = StatColumn("base_on_balls", "BB", "int")
_SAVES = StatColumn("saves", "SV", "int")
_LOSSES = StatColumn("losses", "L", "int")
_FG3 = StatColumn("fg3_pct", "3P%", "pct1")
_GAMES = StatColumn("games", "GP", "int")
_BPG = StatColumn("bpg", "BPG", "dec1")
_CLEAN = StatColumn("clean_sheets", "Clean Sheets", "int")


# ── Baseball ─────────────────────────────────────────────────────────────────────
# Hitters and pitchers are two disjoint stat vocabularies (position H vs P), so they are two
# cohorts with two quirk lists — the same shape as NFL's per-position specs.
_MLB_HITTER = PositionSpec("H", "hitter", "baseball_hitter_fantasy",
                           {"plate_appearances": 300}, _MLB_HITTER_COLS)
_MLB_PITCHER = PositionSpec("P", "pitching", "baseball_pitcher_fantasy",
                            {"innings_pitched": 80}, _MLB_PITCHER_COLS)

_MLB_HITTER_QUIRKS: list[Quirk] = [
    Quirk("slugger", (Filter("slg", "gte", 0.550),), "Slugging {pos} seasons",
          adjective="slugging", axis="power", columns=(_SLG,)),
    Quirk("bombs", (Filter("home_runs", "gte", 35),), "35-homer {pos} seasons",
          adjective="35-homer", axis="power"),
    Quirk("burner", (Filter("stolen_bases", "gte", 30),), "Base-stealing {pos} seasons",
          adjective="base-stealing", axis="speed", columns=(_SB,)),
    Quirk("power-speed", (Filter("home_runs", "gte", 20), Filter("stolen_bases", "gte", 20)),
          "20-20 club seasons", adjective="20-20", axis="power", columns=(_SB,)),
    Quirk("contact", (Filter("hits", "gte", 190),), "190-hit {pos} seasons",
          adjective="190-hit", axis="contact", columns=(_HITS,)),
    Quirk("average", (Filter("avg", "gte", 0.320),), "Batting-title-pace {pos} seasons",
          adjective="batting-title-pace", axis="contact"),
    Quirk("patient", (Filter("base_on_balls", "gte", 90),), "Walk-machine {pos} seasons",
          adjective="walk-machine", axis="discipline", columns=(_BB, _OBP)),
    Quirk("onbase", (Filter("obp", "gte", 0.400),), ".400 on-base {pos} seasons",
          adjective=".400-OBP", axis="discipline", columns=(_OBP,)),
    Quirk("doubles", (Filter("doubles", "gte", 40),), "Doubles-machine {pos} seasons",
          adjective="doubles-machine", axis="gap-power", columns=(_DOUBLES,)),
    Quirk("triples", (Filter("triples", "gte", 10),), "Triples-hitting {pos} seasons",
          adjective="triples-hitting", axis="gap-power", columns=(_TRIPLES,)),
    Quirk("everyday", (Filter("plate_appearances", "gte", 700),), "Every-day {pos} seasons",
          adjective="every-day", axis="volume"),
    Quirk("xbh", (Filter("extra_base_hits", "gte", 75),), "Extra-base-hit {pos} seasons",
          adjective="extra-base", axis="gap-power", columns=(_DOUBLES,)),
    Quirk("iso-power", (Filter("iso", "gte", 0.250),), "Pure-power {pos} seasons",
          adjective="pure-power", axis="power", columns=(_SLG,)),
    # The two opposite shapes of a "good" batting line, which is what makes them fun to rank
    # against each other once a board mixes them.
    Quirk("all-or-nothing", (Filter("home_runs", "gte", 35), Filter("avg", "lte", 0.250)),
          "All-or-nothing {pos} seasons", adjective="all-or-nothing", axis="profile"),
    Quirk("empty-average", (Filter("avg", "gte", 0.310), Filter("home_runs", "lte", 8)),
          "Singles-hitting {pos} seasons", adjective="singles-hitting", axis="profile"),
    Quirk("run-scorer", (Filter("runs", "gte", 120),), "120-run {pos} seasons",
          adjective="120-run", axis="scoring"),
    Quirk("rbi-machine", (Filter("rbi", "gte", 130),), "130-RBI {pos} seasons",
          adjective="130-RBI", axis="scoring"),
    Quirk("thirty-thirty", (Filter("home_runs", "gte", 30), Filter("stolen_bases", "gte", 30)),
          "30-30 club seasons", adjective="30-30", axis="speed", columns=(_SB,)),
]

_MLB_PITCHER_QUIRKS: list[Quirk] = [
    Quirk("strikeout", (Filter("strike_outs", "gte", 220),), "Strikeout-artist {pos} seasons",
          adjective="strikeout-artist", axis="strikeout"),
    Quirk("stingy", (Filter("era", "lte", 2.60),), "Sub-2.60 ERA {pos} seasons",
          adjective="sub-2.60-ERA", axis="run-prevention"),
    Quirk("control", (Filter("whip", "lte", 1.05),), "Pinpoint-control {pos} seasons",
          adjective="pinpoint-control", axis="run-prevention"),
    Quirk("workhorse", (Filter("innings_pitched", "gte", 240),), "Workhorse {pos} seasons",
          adjective="workhorse", axis="volume"),
    Quirk("closer", (Filter("saves", "gte", 35),), "Lights-out closer seasons",
          adjective="lights-out-closer", axis="role", columns=(_SAVES,)),
    Quirk("twenty-game", (Filter("wins", "gte", 20),), "20-win {pos} seasons",
          adjective="20-win", axis="wins"),
    # The fun one: an ace whose record was buried by the team in front of him.
    Quirk("hard-luck", (Filter("losses", "gte", 15), Filter("era", "lte", 3.60)),
          "Hard-luck ace seasons", adjective="hard-luck", axis="wins", columns=(_LOSSES,)),
    Quirk("wild", (Filter("base_on_balls", "gte", 110),), "Effectively-wild {pos} seasons",
          adjective="effectively-wild", axis="command", columns=(_BB,)),
    # Rate stats, not counting stats: these separate a strikeout artist from a workhorse once
    # both clear the innings floor, which a raw K total cannot.
    Quirk("power-arm", (Filter("innings_pitched", "gte", 120), Filter("k_per_9", "gte", 9.5)),
          "Power-arm {pos} seasons", adjective="power-arm", axis="strikeout"),
    Quirk("command", (Filter("innings_pitched", "gte", 120), Filter("k_bb_ratio", "gte", 4.5)),
          "Elite-command {pos} seasons", adjective="elite-command", axis="command"),
    Quirk("nibbler", (Filter("innings_pitched", "gte", 120), Filter("bb_per_9", "gte", 4.5)),
          "Walk-prone {pos} seasons", adjective="walk-prone", axis="command", columns=(_BB,)),
    Quirk("innings-eater", (Filter("innings_pitched", "gte", 260),), "260-inning {pos} seasons",
          adjective="260-inning", axis="volume"),
    Quirk("unlucky", (Filter("era", "lte", 3.00), Filter("wins", "lte", 10),
                      Filter("innings_pitched", "gte", 150)),
          "Great-ERA, no-wins {pos} seasons", adjective="no-run-support", axis="wins",
          columns=(_LOSSES,)),
    Quirk("swingman", (Filter("saves", "gte", 10), Filter("wins", "gte", 8)),
          "Save-and-win {pos} seasons", adjective="save-and-win", axis="role",
          columns=(_SAVES,)),
]

# Baseball's catalog reaches back to 1876, so it earns a much longer era ladder than NFL's.
_MLB_SLICES = decade_slices([None, 1920, 1930, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020])


# ── NBA ──────────────────────────────────────────────────────────────────────────
_NBA_ALL = PositionSpec("ALL", "NBA", "nba_fantasy", {"games": 40}, _NBA_COLS,
                        members=("G", "F", "C"))
_NBA_GUARD = PositionSpec("G", "guard", "nba_fantasy", {"games": 40}, _NBA_COLS)
_NBA_BIG = PositionSpec("BIG", "big-man", "nba_fantasy", {"games": 40}, _NBA_COLS,
                        members=("F", "C"))

_NBA_QUIRKS: list[Quirk] = [
    Quirk("bucket", (Filter("ppg", "gte", 25),), "25-a-night {pos} seasons",
          adjective="25-a-night", axis="scoring"),
    Quirk("efficient", (Filter("ts_pct", "gte", 0.600),), "Hyper-efficient {pos} seasons",
          adjective="hyper-efficient", axis="efficiency"),
    # The inverse archetype — high usage, poor efficiency. A genuinely different puzzle from
    # every "who was best" theme, because the cards look good and grade badly.
    Quirk("gunner", (Filter("ppg", "gte", 20), Filter("ts_pct", "lte", 0.520)),
          "High-volume, low-efficiency {pos} seasons", adjective="high-volume", axis="efficiency"),
    Quirk("sharpshooter", (Filter("fg3_pct", "gte", 0.400),), "40% from deep {pos} seasons",
          adjective="40%-from-deep", axis="shooting", columns=(_FG3,)),
    Quirk("glass", (Filter("rpg", "gte", 12),), "Double-digit-boards {pos} seasons",
          adjective="double-digit-boards", axis="rebounding"),
    Quirk("dime", (Filter("apg", "gte", 8),), "Eight-assist {pos} seasons",
          adjective="eight-assist", axis="playmaking"),
    Quirk("thief", (Filter("spg", "gte", 2.0),), "Pickpocket {pos} seasons",
          adjective="pickpocket", axis="steals"),
    Quirk("swat", (Filter("bpg", "gte", 2.5),), "Shot-blocking {pos} seasons",
          adjective="shot-blocking", axis="blocks", columns=(_BPG,)),
    Quirk("stat-sheet", (Filter("ppg", "gte", 15), Filter("rpg", "gte", 5),
                         Filter("apg", "gte", 5)),
          "Fill-the-stat-sheet {pos} seasons", adjective="fill-the-stat-sheet", axis="all-round"),
    Quirk("disruptor", (Filter("spg", "gte", 1.5), Filter("bpg", "gte", 1.0)),
          "Two-way disruptor {pos} seasons", adjective="two-way-disruptor", axis="defense"),
    Quirk("ironman", (Filter("games", "gte", 80),), "Never-miss-a-game {pos} seasons",
          adjective="never-miss-a-game", axis="availability", columns=(_GAMES,)),
    Quirk("stocks", (Filter("stocks", "gte", 3.0),), "Steal-and-block {pos} seasons",
          adjective="steal-and-block", axis="defense", columns=(_BPG,)),
    Quirk("pra", (Filter("pra", "gte", 40),), "40-PRA {pos} seasons",
          adjective="40-PRA", axis="all-round"),
    Quirk("volume-shooter", (Filter("fg3_pct", "gte", 0.380), Filter("ppg", "gte", 20)),
          "20-point, 38%-from-deep {pos} seasons", adjective="20-and-38%", axis="shooting",
          columns=(_FG3,)),
    Quirk("quiet-efficiency", (Filter("ts_pct", "gte", 0.620), Filter("ppg", "lte", 15)),
          "Quietly-efficient {pos} seasons", adjective="quietly-efficient", axis="efficiency"),
    Quirk("workhorse-scorer", (Filter("games", "gte", 75), Filter("ppg", "gte", 20)),
          "20-a-night, 75-game {pos} seasons", adjective="20-a-night-75-game",
          axis="availability", columns=(_GAMES,)),
]

_NBA_SLICES = decade_slices([None, 1960, 1970, 1980, 1990, 2000, 2010, 2020])


# ── Soccer ───────────────────────────────────────────────────────────────────────
_SOCCER_ATT = PositionSpec("ATT", "attacking", "soccer_attacker_fantasy",
                           {"appearances": 15}, _SOCCER_ATT_COLS, members=("FW", "MF"))
_SOCCER_FW = PositionSpec("FW", "forward", "soccer_attacker_fantasy",
                          {"appearances": 15}, _SOCCER_ATT_COLS)
_SOCCER_MF = PositionSpec("MF", "midfield", "soccer_attacker_fantasy",
                          {"appearances": 15}, _SOCCER_ATT_COLS)
_SOCCER_BACK = PositionSpec("BACK", "back-line", "soccer_defender_fantasy",
                            {"appearances": 15}, _SOCCER_DEF_COLS, members=("DF", "GK"))

_SOCCER_QUIRKS: list[Quirk] = [
    Quirk("prolific", (Filter("goals", "gte", 20),), "20-goal {pos} seasons",
          adjective="20-goal", axis="scoring"),
    Quirk("hat-trick", (Filter("goals", "gte", 25),), "25-goal {pos} seasons",
          adjective="25-goal", axis="scoring"),
    Quirk("provider", (Filter("assists", "gte", 12),), "Assist-king {pos} seasons",
          adjective="assist-king", axis="creation"),
    Quirk("double-figures", (Filter("goals", "gte", 15), Filter("assists", "gte", 10)),
          "15-and-10 {pos} seasons", adjective="15-goal-10-assist", axis="production"),
    Quirk("ever-present", (Filter("appearances", "gte", 38),), "Ever-present {pos} seasons",
          adjective="ever-present", axis="availability"),
    Quirk("wall", (Filter("clean_sheets", "gte", 16),), "Shut-out {pos} seasons",
          adjective="shut-out", axis="clean-sheets", columns=(_CLEAN,), only=("BACK",)),
    # A centre-back or keeper who scored is one of the sport's great oddities. Restricted to
    # the back line for exactly that reason -- see `Quirk.only`.
    Quirk("scoring-defender", (Filter("goals", "gte", 7),), "Goal-scoring {pos} seasons",
          adjective="goal-scoring", axis="scoring", only=("BACK",)),
    Quirk("contributor", (Filter("goal_contributions", "gte", 25),),
          "25-goal-contribution {pos} seasons", adjective="25-contribution", axis="production"),
    # A rate, so a 20-goal season in 25 games outranks 22 goals in 38 — the counting stat
    # cannot express that, and it is the more interesting question.
    Quirk("clinical", (Filter("appearances", "gte", 20), Filter("goals_per_app", "gte", 0.70)),
          "Goal-a-game {pos} seasons", adjective="goal-a-game", axis="efficiency"),
    Quirk("prolific-30", (Filter("goals", "gte", 30),), "30-goal {pos} seasons",
          adjective="30-goal", axis="scoring"),
    Quirk("creator-15", (Filter("assists", "gte", 15),), "15-assist {pos} seasons",
          adjective="15-assist", axis="creation"),
    Quirk("fortress", (Filter("clean_sheets", "gte", 20),), "20-clean-sheet {pos} seasons",
          adjective="20-clean-sheet", axis="clean-sheets", columns=(_CLEAN,), only=("BACK",)),
]

# Soccer's catalog starts at 2002, so eras are thin — the league IS the interesting axis, and
# it's the one dimension `player_seasons` already carries for this sport.
_SOCCER_LEAGUES = ["England", "Spain", "Italy", "Germany", "France", "Portugal",
                   "Netherlands", "Turkey", "Russia", "Belgium", "Scotland", "Greece",
                   "Ukraine", "Denmark", "USA (MLS)"]
_SOCCER_SLICES: tuple[Slice, ...] = decade_slices([None, 2010, 2020]) + tuple(
    Slice(key=slug(league), filters=(Filter("league", "eq", league),),
          suffix=f", {'MLS' if league.startswith('USA') else league}", axis="scope")
    for league in _SOCCER_LEAGUES
)


# ── Tennis ───────────────────────────────────────────────────────────────────────
_TENNIS = PositionSpec("Player", "tour", "tennis_fantasy", {"matches_won": 25}, _TENNIS_COLS)

_TENNIS_QUIRKS: list[Quirk] = [
    Quirk("slam-winner", (Filter("grand_slams", "gte", 2),), "Multi-slam {pos} seasons",
          adjective="multi-slam", axis="slams"),
    Quirk("title-hoard", (Filter("titles", "gte", 6),), "Six-title {pos} seasons",
          adjective="six-title", axis="titles"),
    Quirk("win-machine", (Filter("matches_won", "gte", 60),), "60-win {pos} seasons",
          adjective="60-win", axis="volume"),
    # Played everything, won a lot, lost a lot — the journeyman-grinder shape.
    Quirk("grinder", (Filter("matches_won", "gte", 40), Filter("matches_lost", "gte", 22)),
          "High-mileage {pos} seasons", adjective="high-mileage", axis="volume"),
    Quirk("dominant", (Filter("matches_won", "gte", 50), Filter("matches_lost", "lte", 12)),
          "Barely-lost {pos} seasons", adjective="barely-lost", axis="win-rate"),
    # Tennis stores four counting stats and nothing else, so every quirk written against them
    # was another threshold on the same number. Rates and volume are a different question and
    # reach seasons the counts cannot describe.
    Quirk("win-rate", (Filter("matches_played", "gte", 40), Filter("win_pct", "gte", 0.80)),
          "80%-win-rate {pos} seasons", adjective="80%-win-rate", axis="win-rate"),
    Quirk("iron", (Filter("matches_played", "gte", 85),), "85-match {pos} seasons",
          adjective="85-match", axis="volume"),
    Quirk("slamless", (Filter("matches_won", "gte", 45), Filter("grand_slams", "lte", 0)),
          "45-win, no-slam {pos} seasons", adjective="no-slam", axis="slams"),
    Quirk("slam-sweep", (Filter("grand_slams", "gte", 3),), "Three-slam {pos} seasons",
          adjective="three-slam", axis="slams"),
    Quirk("title-machine", (Filter("titles", "gte", 9),), "Nine-title {pos} seasons",
          adjective="nine-title", axis="titles"),
]

# Tennis stores nationality in `team_abbr`, so country is a first-class slice for this sport.
_TENNIS_NATIONS = ["USA", "ESP", "FRA", "AUS", "GER", "ARG", "SUI", "SRB", "RUS",
                   "SWE", "CZE", "ITA", "GBR"]
_TENNIS_SLICES: tuple[Slice, ...] = decade_slices(
    [None, 1970, 1980, 1990, 2000, 2010, 2020]
) + tuple(
    Slice(key=nation.lower(), filters=(Filter("team", "eq", nation),), suffix=f" ({nation})",
          axis="scope")
    for nation in _TENNIS_NATIONS
)


# NFL's slice vocabulary: decades, plus "Active", plus the eight divisions and two
# conferences. The division axis is the biggest single gap the reference catalogue exposed
# (21% of its titles) and it cost nothing to add: `teams` already carries the mapping.
import datetime as _dt

# Divisions for the other sports that have them. Same shape as NFL's: a set-of-clubs filter on
# its own `division` axis. NBA and MLB both organise by division and their fans talk that way,
# so leaving this NFL-only would have made the axis feel like a football feature.
NBA_DIVISIONS: dict[str, tuple[str, ...]] = {
    "Atlantic":   ("BOS", "BKN", "NY", "PHI", "TOR"),
    "Central":    ("CHI", "CLE", "DET", "IND", "MIL"),
    "Southeast":  ("ATL", "CHA", "MIA", "ORL", "WSH"),
    "Northwest":  ("DEN", "MIN", "OKC", "POR", "UTAH"),
    "Pacific":    ("GS", "LAC", "LAL", "PHX", "SAC"),
    "Southwest":  ("DAL", "HOU", "MEM", "NO", "SA"),
}

MLB_DIVISIONS: dict[str, tuple[str, ...]] = {
    "AL East":    ("BAL", "BOS", "NYY", "TB", "TOR"),
    "AL Central": ("CWS", "CLE", "DET", "KC", "MIN"),
    "AL West":    ("HOU", "LAA", "OAK", "SEA", "TEX"),
    "NL East":    ("ATL", "MIA", "NYM", "PHI", "WSH"),
    "NL Central": ("CHC", "CIN", "MIL", "PIT", "STL"),
    "NL West":    ("ARI", "COL", "LAD", "SD", "SF"),
}


NFL_SLICES: tuple[Slice, ...] = (
    decade_slices(DECADES)
    + (active_slice(_dt.date.today().year),)
    + division_slices(NFL_DIVISIONS)
    + conference_slices(NFL_DIVISIONS)
)

# Every sport gets the "Active" era word the reference catalogue actually leans on (29% of its
# titles say "All-Time", 8% "Active", only 5% name a decade), plus its divisions where it has
# them. `decade_slices` already supplies the all-time slice as key "all".
MLB_SLICES_FULL: tuple[Slice, ...] = (
    _MLB_SLICES + (active_slice(_dt.date.today().year),) + division_slices(MLB_DIVISIONS))
NBA_SLICES_FULL: tuple[Slice, ...] = (
    _NBA_SLICES + (active_slice(_dt.date.today().year),) + division_slices(NBA_DIVISIONS))
SOCCER_SLICES_FULL: tuple[Slice, ...] = (
    _SOCCER_SLICES + (active_slice(_dt.date.today().year),))
TENNIS_SLICES_FULL: tuple[Slice, ...] = (
    _TENNIS_SLICES + (active_slice(_dt.date.today().year),))

SPORTS: dict[str, SportCuration] = {
    "nfl": SportCuration("nfl", POSITIONS, QUIRKS, NFL_SLICES,
                         team_slices=32, team_era_slices=12,
                         team_era_decades=(2000, 2010, 2020)),
    "baseball": SportCuration("baseball", {"H": _MLB_HITTER}, _MLB_HITTER_QUIRKS, MLB_SLICES_FULL,
                              team_slices=30, team_era_slices=16,
                              team_era_decades=(1950, 1970, 1990, 2010)),
    "nba": SportCuration("nba", {"ALL": _NBA_ALL, "G": _NBA_GUARD, "BIG": _NBA_BIG},
                         _NBA_QUIRKS, NBA_SLICES_FULL,
                         team_slices=30, team_era_slices=12,
                         team_era_decades=(1980, 1990, 2000, 2010)),
    "soccer": SportCuration("soccer",
                            {"ATT": _SOCCER_ATT, "FW": _SOCCER_FW, "MF": _SOCCER_MF,
                             "BACK": _SOCCER_BACK},
                            _SOCCER_QUIRKS, SOCCER_SLICES_FULL,
                            team_slices=40, team_era_slices=0),
    "tennis": SportCuration("tennis", {"Player": _TENNIS}, _TENNIS_QUIRKS, TENNIS_SLICES_FULL),
}

# Baseball's pitchers are a second cohort of the same sport with a disjoint stat vocabulary
# (and therefore disjoint quirks), which one `SportCuration` can't express — a quirk list is
# per-sport, not per-position. Registered as its own entry keyed by cohort; `generate.py`
# reads `SportCuration.sport` for the theme's sport, never the dict key.
SPORTS["baseball-pitchers"] = SportCuration(
    "baseball", {"P": _MLB_PITCHER}, _MLB_PITCHER_QUIRKS, MLB_SLICES_FULL,
    team_slices=30, team_era_slices=16,
    team_era_decades=(1950, 1970, 1990, 2010))


# ── Periods: the recency axis ─────────────────────────────────────────────────────
#
# Every slice above answers "which players", on a dimension that is true forever: a decade, a
# franchise, a nation. None of them can say WHEN, closer than a decade. That is the whole
# reason the pipeline could not follow a season: the narrowest available window, "2020s", is
# ten years wide, so "the week that just finished" was not expressible even though
# `season_year` and `week` were already filterable fields.
#
# Period slices carry `axis="period"`, deliberately distinct from `axis="era"` so the roller
# can never AND a decade onto a week and produce a guaranteed-empty pool.
# `generate._AXIS_ORDER` puts period OUTERMOST, so a composed key is stable across the rolled
# and enumerated paths exactly the way era already is.
#
# House style, applied here and everywhere a title fragment is built: NO EM-DASHES. A colon
# separates the period from the theme, a comma joins clauses. tests/test_no_em_dashes.py
# enforces it so it cannot drift back in.


def week_slice(season_year: int, week: int) -> Slice:
    """One real, numbered week of a season. NFL only, because NFL is the only sport whose
    game rows carry a true calendar `week` (NBA and MLB set `week` to a per-player sequence
    index, which is why those sports use `date_window_slice` instead)."""
    return Slice(
        key=f"{season_year}-wk{week:02d}",
        filters=(Filter("season_year", "eq", season_year), Filter("week", "eq", week)),
        prefix=f"{season_year} Week {week}: ",
        axis="period",
    )


def date_window_slice(start: str, end: str, label: str) -> Slice:
    """An inclusive ISO date window, for sports with no numbered week. Filters on
    `event_date`, whose ISO form makes a lexicographic range a chronological one."""
    return Slice(
        key=f"{start}-to-{end}",
        filters=(Filter("event_date", "range", (start, end)),),
        prefix=f"{label}: ",
        axis="period",
    )


def game_quirks(quirks: list[Quirk]) -> list[Quirk]:
    """Season-grain quirks reworded for single-game cards.

    Filters are untouched (a bio predicate like "went undrafted" is as true of a game as of a
    season); only the noun changes, so a card reads "Undrafted WR games" rather than the
    nonsense "Undrafted WR seasons" on a board of eight single games. Keys are UNCHANGED on
    purpose: a key is half of a `puzzle_history` signature, and re-keying every quirk to add a
    grain suffix would orphan the entire served history.
    """
    return [dataclasses.replace(q, title=q.title.replace(" seasons", " games"))
            for q in quirks]


# ── Game-grain cohorts ────────────────────────────────────────────────────────────
#
# Before this, NO PositionSpec set `grain`, so every rolled theme was season grain and the
# generator could not reach a single-game board at all: the only game-grain content in the
# app came from a handful of hand-written curated themes. A period puzzle is inherently
# game-grain (a week has no season totals), so these cohorts are the other half of what makes
# fresh drops possible.
#
# Registered `daily=False`: reachable by the fresh-drop mint only, until turning them on for
# the nightly roll is a measured decision rather than a side effect.

_NFL_GAME_COLS = [
    StatColumn("passing_yards", "Pass Yds", "comma_int"),
    StatColumn("passing_tds", "Pass TD", "int"),
    StatColumn("rushing_yards", "Rush Yds", "comma_int"),
    StatColumn("rushing_tds", "Rush TD", "int"),
    StatColumn("receptions", "Rec", "int"),
    StatColumn("receiving_yards", "Rec Yds", "comma_int"),
    StatColumn("receiving_tds", "Rec TD", "int"),
]

# Single-game floors, roughly a fifth of the season floors above. Low enough that ONE week of
# one league still fields a pool (a season floor like 600 receiving yards matches nobody in a
# single game), high enough to keep out the two-catch afternoons.
NFL_GAME_POSITIONS: dict[str, PositionSpec] = {
    "WR": PositionSpec("WR", "WR", "nfl_skill_ppr_game", {"receiving_yards": 50},
                       _WR_TE_COLS, light_lb=190, heavy_lb=225, grain="game", pool_cap=24),
    "TE": PositionSpec("TE", "TE", "nfl_skill_ppr_game", {"receiving_yards": 35},
                       _WR_TE_COLS, light_lb=230, heavy_lb=260, grain="game", pool_cap=24),
    "RB": PositionSpec("RB", "RB", "nfl_skill_ppr_game", {"rushing_yards": 45}, [
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
        StatColumn("ypc", "Yds/Carry", "dec1"),
        StatColumn("receptions", "Rec", "int"),
        StatColumn("receiving_yards", "Rec Yds", "comma_int"),
    ], light_lb=200, heavy_lb=230, grain="game", pool_cap=24),
    "QB": PositionSpec("QB", "QB", "nfl_qb_fantasy_game", {"passing_yards": 180}, [
        StatColumn("passing_yards", "Pass Yds", "comma_int"),
        StatColumn("passing_tds", "Pass TD", "int"),
        StatColumn("interceptions", "INT", "int"),
        StatColumn("rushing_yards", "Rush Yds", "comma_int"),
        StatColumn("rushing_tds", "Rush TD", "int"),
    ], light_lb=210, heavy_lb=245, grain="game", pool_cap=24),
    # Cross-positional. One unified PPR formula judges every position on the same axis, so a
    # quarterback's 380-and-4 sits directly against a running back's 150-and-2.
    #
    # `min_stats` MUST stay position-neutral: entries are ANDed, so any per-stat floor
    # (receiving_yards, passing_yards) silently zeroes out every position that doesn't record
    # that stat. This is the same constraint the curated `nfl-total-fantasy` theme documents,
    # and it is why the gate here is empty and the pool_cap does the selecting.
    "ANY": PositionSpec("ANY", "player", "nfl_fantasy_game", {}, _NFL_GAME_COLS,
                        members=("QB", "RB", "WR", "TE"), grain="game", pool_cap=24),
}

# Single-game STAT hooks. The reason this list has to exist: every quirk in `QUIRKS` that is
# about production carries a SEASON threshold ("300-carry", "100-catch", "35-touchdown"), and
# not one of them can be met inside a single game. So at game grain the only quirks that ever
# survived the viability gate were the biographical ones, and a replayed 2024 season came out
# reading like a scouting report no matter how the draw was weighted. Weighting cannot fix a
# pool that contains nothing else; more material can.
#
# These are also the shape the reference catalogue actually leads with. BallGame's everyday
# titles name the STAT ("Top Rookie Receiving TD Seasons", "Top Single-Game Rushing Yard
# Games"), not the player's draft round.
#
# Titles carry no {pos}: each quirk is bound with `only=` to the cohorts whose players record
# that stat, so "100-yard receiving games" is already unambiguous and "100-yard WR receiving
# games" would just be redundant.
_REC = ("WR", "TE", "ANY")
_RUSH = ("RB", "QB", "ANY")
_PASS = ("QB", "ANY")

NFL_GAME_QUIRKS: list[Quirk] = [
    # THRESHOLDS ARE WEEK-SCALE, NOT HIGHLIGHT-SCALE, and that distinction is the whole reason
    # the first draft of this list produced nothing. A 150-yard receiving game is the right
    # number for "impressive"; across ONE week of sixteen games only two players clear it, so
    # the board cannot be built. Measured medians per 2024 week, which is what these are tuned
    # against (a viable board needs roughly twelve in the pool):
    #     rec >= 80y: 20     rec >= 100y: 9      10+ catches: 3
    #     rush >= 70y: 16    rush >= 100y: 7     20+ carries: 7
    #     pass >= 250y: 13   pass >= 300y: 5     3+ pass TD: 2
    # Re-measure before moving any of these; they are empirical, not editorial.
    Quirk("rec80", (Filter("receiving_yards", "gte", 80),), "Eighty-yard receiving games",
          adjective="eighty-yard-receiving", axis="rec-volume", only=("WR", "TE", "ANY")),
    Quirk("catch8", (Filter("receptions", "gte", 8),), "Eight-catch games",
          adjective="eight-catch", axis="rec-usage", only=("WR", "TE", "ANY")),
    Quirk("bigplay", (Filter("ypr", "gte", 18),), "Big-play receiving games (18+ a catch)",
          adjective="big-play", axis="rec-efficiency", only=("WR", "TE", "ANY")),
    Quirk("rush70", (Filter("rushing_yards", "gte", 70),), "Seventy-yard rushing games",
          adjective="seventy-yard-rushing", axis="rush-volume", only=("RB", "QB", "ANY")),
    Quirk("workhorse-game", (Filter("carries", "gte", 15),), "Fifteen-carry games",
          adjective="fifteen-carry", axis="rush-usage", only=("RB", "QB", "ANY")),
    Quirk("explosive-game", (Filter("ypc", "gte", 5.5),), "Five-and-a-half-a-carry games",
          adjective="five-and-a-half-a-carry", axis="rush-efficiency", only=("RB", "QB", "ANY")),
    Quirk("pass250", (Filter("passing_yards", "gte", 250),), "250-yard passing games",
          adjective="250-yard-passing", axis="pass-volume", only=("QB", "ANY")),
    Quirk("scrim100", (Filter("scrimmage_yards", "gte", 100),), "Hundred-yard scrimmage games",
          adjective="hundred-scrimmage", axis="all-purpose"),
]


SPORTS["nfl-games"] = SportCuration(
    "nfl", NFL_GAME_POSITIONS, game_quirks(QUIRKS) + NFL_GAME_QUIRKS, NFL_SLICES,
    team_slices=32, team_era_slices=0, daily=False)
