"""Editorial config for the niche-theme generator (see generate.py).

This is the "what/how it's framed" half: which positions, eras, bio-quirks and first
names to try, how to title them, what to forbid, and how many to keep. The generator
(`generate.py`) is the "is it a fair puzzle" half — it builds each candidate and keeps
only the ones with 8 close, recognizable seasons and a clean keep/cut boundary.
"""
from __future__ import annotations

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

    # Which single dimension this quirk slices. Two quirks sharing a non-empty axis are
    # structurally redundant to AND together (two age bands, two draft bands, two flavors of
    # "he hit for power") and `redundant_pair` skips the combo. NFL's quirks predate this
    # field and are still grouped by the legacy key sets below, so both mechanisms are live.
    axis: str = ""
    # Stat columns this quirk is *about*, promoted to the front of the card so a puzzle
    # titled "20-20 club seasons" actually shows HR and SB. Empty = leave the position
    # spec's columns alone (every NFL quirk is a bio filter, so none of them set this).
    columns: tuple[StatColumn, ...] = ()
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
    """
    key: str
    filters: tuple[Filter, ...] = ()
    prefix: str = ""
    suffix: str = ""


def decade_slices(decades: list[int | None]) -> tuple[Slice, ...]:
    """`DECADES`-style list → slices. Reproduces the exact pre-existing NFL keys and titles
    (`gen-wr-2010-undrafted`, "2010s Undrafted WR gems"), so no NFL signature changes."""
    return tuple(
        Slice(key=str(d) if d is not None else "all",
              filters=() if d is None else (Filter("decade", "eq", d),),
              prefix=decade_prefix(d))
        for d in decades
    )


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
]

# Soccer's catalog starts at 2002, so eras are thin — the league IS the interesting axis, and
# it's the one dimension `player_seasons` already carries for this sport.
_SOCCER_LEAGUES = ["England", "Spain", "Italy", "Germany", "France", "Portugal",
                   "Netherlands", "Turkey", "Russia", "Belgium", "Scotland", "Greece",
                   "Ukraine", "Denmark", "USA (MLS)"]
_SOCCER_SLICES: tuple[Slice, ...] = decade_slices([None, 2010, 2020]) + tuple(
    Slice(key=slug(league), filters=(Filter("league", "eq", league),),
          suffix=f" — {'MLS' if league.startswith('USA') else league}")
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
]

# Tennis stores nationality in `team_abbr`, so country is a first-class slice for this sport.
_TENNIS_NATIONS = ["USA", "ESP", "FRA", "AUS", "GER", "ARG", "SUI", "SRB", "RUS",
                   "SWE", "CZE", "ITA", "GBR"]
_TENNIS_SLICES: tuple[Slice, ...] = decade_slices(
    [None, 1970, 1980, 1990, 2000, 2010, 2020]
) + tuple(
    Slice(key=nation.lower(), filters=(Filter("team", "eq", nation),), suffix=f" ({nation})")
    for nation in _TENNIS_NATIONS
)


SPORTS: dict[str, SportCuration] = {
    "nfl": SportCuration("nfl", POSITIONS, QUIRKS, decade_slices(DECADES)),
    "baseball": SportCuration("baseball", {"H": _MLB_HITTER}, _MLB_HITTER_QUIRKS, _MLB_SLICES),
    "nba": SportCuration("nba", {"ALL": _NBA_ALL, "G": _NBA_GUARD, "BIG": _NBA_BIG},
                         _NBA_QUIRKS, _NBA_SLICES),
    "soccer": SportCuration("soccer",
                            {"ATT": _SOCCER_ATT, "FW": _SOCCER_FW, "MF": _SOCCER_MF,
                             "BACK": _SOCCER_BACK},
                            _SOCCER_QUIRKS, _SOCCER_SLICES),
    "tennis": SportCuration("tennis", {"Player": _TENNIS}, _TENNIS_QUIRKS, _TENNIS_SLICES),
}

# Baseball's pitchers are a second cohort of the same sport with a disjoint stat vocabulary
# (and therefore disjoint quirks), which one `SportCuration` can't express — a quirk list is
# per-sport, not per-position. Registered as its own entry keyed by cohort; `generate.py`
# reads `SportCuration.sport` for the theme's sport, never the dict key.
SPORTS["baseball-pitchers"] = SportCuration(
    "baseball", {"P": _MLB_PITCHER}, _MLB_PITCHER_QUIRKS, _MLB_SLICES)
