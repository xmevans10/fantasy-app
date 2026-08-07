"""The Grid's axis vocabulary — what a row or column of the board can *be*.

Until 2026-07-27 the board was hardcoded to teams x decades: rows were always three team
abbreviations, columns always three decades, at every layer from this generator through the
`puzzles` content JSON to the SwiftUI layout. Every board ever minted had that shape.

Immaculate Grid (the reference product — see docs/grid-axes-research.md) does the opposite: all
six axes are the same type, and each independently carries a team, a statistical achievement, or
an award. That symmetry is what produces its most recognisable cell, team x team ("who played
for both?"), which the old shape could not express at all.

This module is the editorial half of the fix — the catalog of axes each sport can offer, kept
apart from `grid.py`'s selection/viability machinery for the same reason `themes.py` is kept
apart from `assemble.py`. An axis is nothing but a label plus a tuple of `themes.Filter`
predicates, so the existing declarative filter engine does all the actual matching and no second
predicate language enters the codebase (AGENTS.md §4).

## Grain, and why team x team needs it

Immaculate Grid's two documented combination rules:

  * team + season-stat / team + award -> must be the SAME season ("1,000 yards *as a Bear*").
  * team + career-stat -> career total anywhere, and only one game played for the team.

So an axis carries a `grain`. A cell is satisfied by a player when **one** season satisfies every
`season`-grain axis, while every `career`-grain axis may be satisfied by any season in that
player's history.

That distinction is load-bearing, not decorative: a single season row has exactly one team, so
two `season`-grain team axes can never be co-satisfied and a team x team board would be unviable
by construction. "Played for both" is inherently a career-level question, which is why the
team x team archetype uses `career`-grain team axes on both dimensions.

## Why thresholds are curated, not derived

A percentile over the live distribution would be self-maintaining, but it produces labels like
"923+ Rushing Yards" — a number no fan recognises. Round milestones are the whole point of a
stat axis ("1,000+ Rush Yds", "30+ HR", "20+ PPG"), so these are hand-set against real
significance and validated by the viability gate rather than computed.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from . import soccer_leagues
from .themes import Filter


@dataclass(frozen=True)
class GridAxis:
    """One row or column of the board."""

    kind: str                        # 'team' | 'decade' | 'position' | 'stat'
    label: str                       # what renders on the board: "KC", "2000s", "30+ HR"
    filters: tuple[Filter, ...]      # ANDed; a season matches the axis when all pass
    grain: str = "season"            # 'season' (see module docstring) | 'career'
    # Stable machine identity, used for `grid_history` dedup and as the client-side hint for how
    # to render the label (a team axis draws a colored crest chip, everything else draws text).
    key: str = ""
    # Team axes only: the franchise's identity, which is NOT the label alone. Shipped in content
    # so the client can resolve the right crest and colors — `TeamAbbrChip(sport:abbr:league:)`
    # already takes a league for exactly this collision reason.
    abbr: str = ""
    league: str = ""

    def matches(self, season) -> bool:
        return all(f.matches(season) for f in self.filters)


# Sports whose `team_abbr` is NOT unique on its own, so a team axis must be scoped by league.
#
# Soccer codes are derived from club names and collide hard across countries. Measured live
# 2026-07-27: 152 of 954 soccer abbreviations carry rows from more than one league and 51 are
# genuinely mixed (>10% of rows from the minority club) — including the game's most recognisable
# clubs. MCI is Manchester City (England, 288 rows) AND Melbourne City (Australia, 132); TOR is
# Torino (322) and Toronto FC (186); GAL is Galatasaray (301) and LA Galaxy (140); MON is Monaco
# (294) and Montreal (134); DUN is a 49/51 split. An unscoped "MCI" axis accepts either club's
# players as a valid answer, which is simply wrong.
LEAGUE_SCOPED_SPORTS = frozenset({"soccer"})


def league_code(league: str) -> str:
    """Short nation code for a league label — "England" -> "ENG", "Australia" -> "AUS",
    "USA (MLS)" -> "USA".

    Derived from `soccer_leagues.top_flight_slug` (the committed competition table) rather than a
    new hand-written map: that file already answers "which competition key is England's top
    flight?" as `eng.1`, and the prefix of that key IS the nation code. A second table would be
    the exact drift AGENTS.md §4 warns about. Unknown labels fall back to their first three
    letters, so a competition added to the catalog before the CSV still gets a sane code.
    """
    if not league:
        return ""
    slug = soccer_leagues.top_flight_slug(league)
    if slug:
        return slug.split(".", 1)[0].upper()
    return "".join(c for c in league if c.isalnum())[:3].upper()


def qualified_team_label(abbr: str, league: str) -> str:
    """The label a league-scoped team axis actually renders: "MCI-ENG", "MCI-AUS", "TOR-ITA".

    The league scoping below already fixes the *answer set*, but on its own it leaves two axes
    both reading "MCI" — correct underneath, indistinguishable on screen. Folding the nation code
    into the label makes the board self-describing, so a player never has to infer which club a
    shared code means from the crest alone.
    """
    code = league_code(league)
    return f"{abbr}-{code}" if code else abbr


def team_axis(abbr: str, *, league: str = "", grain: str = "season") -> GridAxis:
    """`grain='career'` is "ever played for them" — the team x team semantics.

    `league` narrows the axis to one club when the abbreviation is ambiguous (see
    `LEAGUE_SCOPED_SPORTS`). It participates in the filter, the key AND the rendered label, so
    MCI/England and MCI/Australia are genuinely different axes *and* read differently on the
    board ("MCI-ENG" vs "MCI-AUS"). `abbr`/`league` still ship separately in the content because
    the crest and color lookup must key on the raw code, not the qualified label.
    """
    filters: tuple[Filter, ...] = (Filter("team", "eq", abbr),)
    if league:
        filters += (Filter("league", "eq", league),)
    return GridAxis(kind="team", label=qualified_team_label(abbr, league), filters=filters,
                    grain=grain,
                    key=f"team:{abbr}@{league}" if league else f"team:{abbr}",
                    abbr=abbr, league=league)


def decade_axis(decade: int) -> GridAxis:
    return GridAxis(kind="decade", label=f"{decade}s", filters=(Filter("decade", "eq", decade),),
                    key=f"decade:{decade}")


def position_axis(position: str, label: str) -> GridAxis:
    return GridAxis(kind="position", label=label, filters=(Filter("position", "eq", position),),
                    key=f"pos:{position}")


@dataclass(frozen=True)
class StatAxisSpec:
    """A curated statistical milestone. `extra` carries volume gates — a rate stat without one is
    a trap: a .400 average over 3 plate appearances is not "a .300 hitter", and without the gate
    the cell fills with September call-ups instead of the recognisable names the axis promises.
    """

    label: str
    stat: str
    op: str                                  # 'gte' for counting stats, 'lte' for ERA/WHIP
    value: float
    extra: tuple[Filter, ...] = field(default_factory=tuple)

    def axis(self) -> GridAxis:
        return GridAxis(kind="stat", label=self.label,
                        filters=(Filter(self.stat, self.op, self.value),) + self.extra,
                        key=f"stat:{self.stat}:{self.op}:{self.value:g}")


# Stat keys verified present in the live `player_seasons` catalog on 2026-07-27 (counts are rows
# carrying the key, career=false): nfl ~100k on every passing/rushing/receiving key; baseball
# ~52k batting / ~31k pitching; nba ~51k counting + ~24k rate; soccer ~79k; tennis ~8.5k.
_STATS: dict[str, tuple[StatAxisSpec, ...]] = {
    "nfl": (
        StatAxisSpec("4,000+ Pass Yds", "passing_yards", "gte", 4000),
        StatAxisSpec("3,000+ Pass Yds", "passing_yards", "gte", 3000),
        StatAxisSpec("30+ Pass TD", "passing_tds", "gte", 30),
        StatAxisSpec("1,000+ Rush Yds", "rushing_yards", "gte", 1000),
        StatAxisSpec("1,500+ Rush Yds", "rushing_yards", "gte", 1500),
        StatAxisSpec("10+ Rush TD", "rushing_tds", "gte", 10),
        StatAxisSpec("1,000+ Rec Yds", "receiving_yards", "gte", 1000),
        StatAxisSpec("1,400+ Rec Yds", "receiving_yards", "gte", 1400),
        StatAxisSpec("80+ Receptions", "receptions", "gte", 80),
        StatAxisSpec("10+ Rec TD", "receiving_tds", "gte", 10),
        # Defensive milestones — added alongside `nfl_nflverse_defense.py`, the provider that
        # first put defenders (e.g. Khalil Mack, previously unsearchable anywhere in the app)
        # into `player_seasons`. Stat keys match that provider's vocabulary exactly.
        StatAxisSpec("10+ Sacks", "sacks", "gte", 10),
        StatAxisSpec("15+ Sacks", "sacks", "gte", 15),
        StatAxisSpec("100+ Tackles", "tackles_combined", "gte", 100),
        StatAxisSpec("125+ Tackles", "tackles_combined", "gte", 125),
        StatAxisSpec("5+ INT", "def_interceptions", "gte", 5),
        StatAxisSpec("3+ Forced Fumbles", "forced_fumbles", "gte", 3),
    ),
    "nba": (
        StatAxisSpec("20+ PPG", "ppg", "gte", 20, (Filter("games", "gte", 40),)),
        StatAxisSpec("25+ PPG", "ppg", "gte", 25, (Filter("games", "gte", 40),)),
        StatAxisSpec("10+ RPG", "rpg", "gte", 10, (Filter("games", "gte", 40),)),
        StatAxisSpec("8+ APG", "apg", "gte", 8, (Filter("games", "gte", 40),)),
        StatAxisSpec("2+ BPG", "bpg", "gte", 2, (Filter("games", "gte", 40),)),
        StatAxisSpec("2+ SPG", "spg", "gte", 2, (Filter("games", "gte", 40),)),
        StatAxisSpec("1,500+ Points", "points", "gte", 1500),
        StatAxisSpec("2,000+ Points", "points", "gte", 2000),
        StatAxisSpec("700+ Rebounds", "rebounds", "gte", 700),
        StatAxisSpec("500+ Assists", "assists", "gte", 500),
    ),
    "baseball": (
        StatAxisSpec("30+ HR", "home_runs", "gte", 30),
        StatAxisSpec("40+ HR", "home_runs", "gte", 40),
        StatAxisSpec("100+ RBI", "rbi", "gte", 100),
        StatAxisSpec("100+ Runs", "runs", "gte", 100),
        StatAxisSpec("180+ Hits", "hits", "gte", 180),
        StatAxisSpec("30+ Stolen Bases", "stolen_bases", "gte", 30),
        # Rate stats gated on playing time — see StatAxisSpec.extra.
        StatAxisSpec(".300+ AVG", "avg", "gte", 0.300, (Filter("plate_appearances", "gte", 400),)),
        StatAxisSpec(".900+ OPS", "ops", "gte", 0.900, (Filter("plate_appearances", "gte", 400),)),
        StatAxisSpec("15+ Wins", "wins", "gte", 15),
        StatAxisSpec("200+ Strikeouts", "strike_outs", "gte", 200),
        StatAxisSpec("30+ Saves", "saves", "gte", 30),
        StatAxisSpec("Sub-3.00 ERA", "era", "lte", 3.00, (Filter("innings_pitched", "gte", 150),)),
    ),
    "soccer": (
        StatAxisSpec("10+ Goals", "goals", "gte", 10),
        StatAxisSpec("15+ Goals", "goals", "gte", 15),
        StatAxisSpec("20+ Goals", "goals", "gte", 20),
        StatAxisSpec("10+ Assists", "assists", "gte", 10),
        StatAxisSpec("30+ Appearances", "appearances", "gte", 30),
        StatAxisSpec("10+ Clean Sheets", "clean_sheets", "gte", 10),
    ),
    "tennis": (
        StatAxisSpec("3+ Titles", "titles", "gte", 3),
        StatAxisSpec("Won a Major", "grand_slams", "gte", 1),
        StatAxisSpec("50+ Match Wins", "matches_won", "gte", 50),
    ),
}

# Display names for the raw position codes the catalog stores. Sports whose position column is a
# single degenerate value (tennis is all "Player") are absent, which is what disables the
# position archetype for them — see `position_axes`.
_POSITIONS: dict[str, dict[str, str]] = {
    "nfl": {"QB": "QB", "RB": "RB", "WR": "WR", "TE": "TE"},
    "nba": {"G": "Guards", "F": "Forwards", "C": "Centers"},
    "baseball": {"H": "Hitters", "P": "Pitchers"},
    "soccer": {"GK": "Keepers", "DF": "Defenders", "MF": "Midfielders", "FW": "Forwards"},
}

# Multi-code position groups, for the (currently NFL-only) case where the catalog's raw
# `position` column is granular rather than a single coarse code `_POSITIONS` assumes.
# `nfl_nflverse_defense.py` deliberately keeps individual codes (OLB, CB, DT, ...) rather than
# collapsing them at ingest time — see that provider's docstring — so the grouping happens here
# via `Filter("position", "in", codes)` instead. Each entry is (key, codes, label); `key` keeps
# these axes distinct from `_POSITIONS` entries in `grid_history` dedup.
_POSITION_GROUPS: dict[str, tuple[tuple[str, tuple[str, ...], str], ...]] = {
    "nfl": (
        ("dl", ("DE", "DT", "NT", "DL"), "D-Line"),
        ("lb", ("OLB", "MLB", "ILB", "LB"), "Linebackers"),
        ("db", ("CB", "FS", "SS", "S", "SAF", "DB"), "Defensive Backs"),
    ),
}

# Sports where `team_abbr` is a franchise a player can actually move between. Tennis is excluded
# on purpose: there `team_abbr` is the player's COUNTRY, which is fixed for a career, so a
# team x team board ("played for both USA and CRO") would be unviable for every player alive.
TEAM_MOBILE_SPORTS = frozenset({"nfl", "nba", "baseball", "soccer"})


def position_family(sport: str, code: str) -> str:
    """The coarse family a raw catalog position code belongs to — `'lb'` for OLB/MLB/ILB/LB,
    `'db'` for the secondary, `'dl'` for the front, and the code itself for everything the
    groups don't cover (QB, WR, G, H, FW, …).

    Exposed for callers outside The Grid (whoami_pool.py, which needs a scoring cohort per
    position) so that "which codes are linebackers" stays one fact in one place. Kept here
    rather than moved somewhere neutral because `_POSITION_GROUPS` is still primarily Grid
    axis config; this is a read of it, not a second copy.
    """
    for key, codes, _label in _POSITION_GROUPS.get(sport, ()):
        if code in codes:
            return key
    return code


def stat_axes(sport: str) -> list[GridAxis]:
    return [spec.axis() for spec in _STATS.get(sport, ())]


def position_axes(sport: str) -> list[GridAxis]:
    axes = [position_axis(code, label) for code, label in _POSITIONS.get(sport, {}).items()]
    axes += [
        GridAxis(kind="position", label=label, filters=(Filter("position", "in", codes),),
                 key=f"pos:{key}")
        for key, codes, label in _POSITION_GROUPS.get(sport, ())
    ]
    return axes
