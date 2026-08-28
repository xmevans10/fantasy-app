"""Puzzle SHAPES: ways of arranging the data that are not "eight rows matching a predicate".

Every theme the generator could build before this was the same arrangement underneath. Pick a
cohort, filter it, rank by grade, take eight close ones, one row per person. The axes varied
(era, franchise, league, quirk) but the shape never did.

These change the shape instead of the filter:

  cross_positional   one unified scale across every position, so a QB's day is directly
                     comparable to a RB's. Proven by the curated `nfl-total-fantasy` theme but
                     unreachable by the generator, because no PositionSpec grouped the
                     positions under one scale. Lives in curation as the "ANY" spec; the
                     builder here is the season-grain sibling of the game-grain flagship.
  career_ladder      eight seasons of ONE player. Structurally impossible before
                     `Theme.dedupe_person`, which exists precisely to stop a star appearing
                     twice on a card.
  one_roster         eight team-mates from one club in one season, cross-positional.
  franchise_ladder   one club, one position, eight seasons spread across its whole history
                     rather than clustered in its best era (`window_mode="spread"`).
  same_game          eight players from ONE real game, both sides. Needs `event_date`, which
                     is why it could not exist before the fresh-drop work put real dates on
                     game rows.

Each builder returns a `Theme`; each has a `*_subjects()` companion that finds the subjects the
data can actually support, so nothing here hardcodes a roster of players or clubs (AGENTS.md
§2: a literal list encodes "now" and rots silently).

House style throughout: no em-dashes in any title.
"""
from __future__ import annotations

import collections

from . import curation
from .models import RawSeason, slug
from .themes import Filter, Theme

# A shape needs enough rows to fill eight slots with room for the boundary check to fail on a
# few. Ten is the floor everything here screens on.
MIN_POOL = 10


def _spec_theme(key: str, title: str, spec: curation.PositionSpec, sport: str,
                filters: tuple[Filter, ...], **kw) -> Theme:
    base = dict(
        key=key, title=title, sport=sport, scale=spec.scale, positions=spec.position_set,
        min_stats=dict(spec.min_stats), columns=list(spec.columns), filters=filters,
        grain=spec.grain, pool_cap=spec.pool_cap,
    )
    base.update(kw)
    return Theme(**base)


# ── 01 · Cross-positional showdown ────────────────────────────────────────────

def cross_positional(sport: str, spec: curation.PositionSpec,
                     slice_: curation.Slice | None = None,
                     window_mode: str = "close") -> Theme:
    """One scale, every position. `spec` must be a cross-positional spec whose `min_stats`
    are position-neutral: entries are ANDed, so a `receiving_yards` floor would silently
    exclude every quarterback in the pool."""
    sl = slice_ or curation.Slice(key="all")
    label = "performances" if spec.grain == "game" else "seasons"
    title = f"{sl.prefix}best {label} at any position{sl.suffix}"
    return _spec_theme(f"shape-anypos-{sport}-{sl.key}".lower(),
                       title[0].upper() + title[1:], spec, sport, sl.filters,
                       window_mode=window_mode)


# ── 02 · Career ladder ────────────────────────────────────────────────────────

def career_ladder_subjects(seasons: list[RawSeason], sport: str, positions: frozenset[str],
                           minimum: int = MIN_POOL) -> list[str]:
    """Players with at least `minimum` season rows in this cohort, most rows first. These are
    the only subjects a ladder can be built for."""
    counts: collections.Counter[str] = collections.Counter()
    for s in seasons:
        if s.sport == sport and s.position in positions and not s.career and s.week is None:
            counts[s.name] += 1
    return [name for name, n in counts.most_common() if n >= minimum]


def career_ladder(sport: str, player: str, spec: curation.PositionSpec) -> Theme:
    """Eight seasons of one player, spread across their career.

    `dedupe_person=False` is the whole trick, and it is deliberately narrow: everywhere else
    that flag staying True is what stops one human holding two slots on a card.
    """
    return _spec_theme(
        f"shape-career-{sport}-{slug(player)}".lower(),
        f"Rank {player}'s seasons",
        spec, sport, (Filter("name", "eq", player),),
        dedupe_person=False, window_mode="spread", pool_cap=40,
    )


# ── 03 · One roster, one season ───────────────────────────────────────────────

def one_roster_subjects(seasons: list[RawSeason], sport: str, positions: frozenset[str],
                        minimum: int = MIN_POOL) -> list[tuple[str, int]]:
    """(team, season_year) pairs with enough graded team-mates to fill a board."""
    counts: collections.Counter[tuple[str, int]] = collections.Counter()
    for s in seasons:
        if (s.sport == sport and s.position in positions and s.team_abbr
                and not s.career and s.week is None):
            counts[(s.team_abbr, s.season_year)] += 1
    return [pair for pair, n in counts.most_common() if n >= minimum]


def team_names(teams: list[dict], sport: str) -> dict[str, str]:
    """`{team_abbr: full_name}` for one sport, from the `teams` table. A title reads "The 2020
    Chiefs", not "The 2020 KC"; the abbreviation is a database key, not something to show a
    player. Falls back to the abbreviation wherever a club has no name on file."""
    return {row["team_abbr"]: (row.get("full_name") or row["team_abbr"])
            for row in teams if row.get("sport") == sport and row.get("team_abbr")}


def one_roster(sport: str, team: str, season_year: int,
               spec: curation.PositionSpec, display: str | None = None) -> Theme:
    """Eight team-mates from one club in one season, judged on one scale.

    `display` is the club's readable name (see `team_names`); the KEY still uses the
    abbreviation, so a club being renamed changes what a player reads without orphaning any
    `puzzle_history` signature."""
    return _spec_theme(
        f"shape-roster-{sport}-{slug(team)}-{season_year}".lower(),
        f"The {season_year} {display or team}, ranked",
        spec, sport,
        (Filter("team", "eq", team), Filter("season_year", "eq", season_year)),
    )


# ── 04 · Franchise ladder ─────────────────────────────────────────────────────

def franchise_ladder_subjects(seasons: list[RawSeason], sport: str, positions: frozenset[str],
                              min_span: int = 20, minimum: int = MIN_POOL) -> list[str]:
    """Clubs with a deep enough, wide enough history at this position. `min_span` is the point
    of the shape: a club with twelve seasons all inside one decade is a normal board, not a
    ladder through history."""
    years: dict[str, list[int]] = {}
    for s in seasons:
        if (s.sport == sport and s.position in positions and s.team_abbr
                and not s.career and s.week is None):
            years.setdefault(s.team_abbr, []).append(s.season_year)
    out = [(team, len(ys), max(ys) - min(ys)) for team, ys in years.items()]
    out = [(t, n, span) for t, n, span in out if n >= minimum and span >= min_span]
    out.sort(key=lambda r: (-r[2], -r[1]))
    return [team for team, _, _ in out]


def franchise_ladder(sport: str, team: str, spec: curation.PositionSpec,
                     display: str | None = None) -> Theme:
    """One club, one position, eight seasons across its whole history.

    Honest tension, recorded here rather than discovered later: a spread window has wider
    grade gaps than a close one, so this board is EASIER to sort than a normal one. Holding it
    to a single position is the compensation, because eras are hard to separate when the role
    is constant.
    """
    return _spec_theme(
        f"shape-franchise-{sport}-{slug(team)}-{spec.pos}".lower(),
        f"Every era of {display or team} {spec.label}s, ranked",
        spec, sport, (Filter("team", "eq", team),),
        window_mode="spread", pool_cap=60,
    )


# ── 05 · Same game ────────────────────────────────────────────────────────────

def same_game_subjects(seasons: list[RawSeason], sport: str, positions: frozenset[str],
                       minimum: int = MIN_POOL) -> list[tuple[str, str, str]]:
    """(event_date, team, opponent) triples with enough rows across BOTH sides to fill a board.

    A game is identified by its date plus the unordered pair of teams, so the two halves of
    one fixture collapse to one subject instead of being counted twice.
    """
    counts: collections.Counter[tuple[str, str, str]] = collections.Counter()
    for s in seasons:
        if (s.sport == sport and s.position in positions and s.week is not None
                and s.event_date and s.team_abbr and s.opponent):
            home, away = sorted((s.team_abbr, s.opponent))
            counts[(s.event_date, home, away)] += 1
    return [key for key, n in counts.most_common() if n >= minimum]


def same_game(sport: str, event_date: str, team_a: str, team_b: str,
              spec: curation.PositionSpec) -> Theme:
    """Eight players from one real game, both sides of it.

    Filtering on `team in (a, b)` plus the exact date is what picks a single fixture: within
    one date, only these two clubs played each other.
    """
    return _spec_theme(
        f"shape-game-{sport}-{event_date}-{slug(team_a)}-{slug(team_b)}".lower(),
        f"{team_a} vs {team_b}, {_pretty_date(event_date)}: who had the better day?",
        spec, sport,
        (Filter("event_date", "eq", event_date),
         Filter("team", "in", (team_a, team_b))),
        window_mode="top",
    )


def _pretty_date(iso: str) -> str:
    """'2024-09-08' -> 'Sep 8, 2024'. No dashes in a user-facing date."""
    import datetime as dt
    try:
        d = dt.date.fromisoformat(iso)
    except ValueError:
        return iso
    return f"{d.strftime('%b')} {d.day}, {d.year}"


# ── Bonus · The kit-colour axis ───────────────────────────────────────────────
#
# The only entry here that is a new FILTER dimension rather than a new arrangement. Colours
# already existed in the `teams` table, populated by `--teams`; what was missing is that
# generation never joined them, so `RawSeason` had no colour to filter on.

# Hue buckets, in degrees, as the boundaries a person would actually name. Deliberately coarse:
# "teams in blue" is a vibe, not a colorimetric claim, and a fine-grained bucketing would put
# two clubs a fan calls blue into different boards.
_HUE_FAMILIES: tuple[tuple[str, float, float], ...] = (
    # The orange/gold split sits at 36 deg, not the tidy 45: Steelers/Packers gold (#FFB612)
    # computes to 41.5 deg, and a board of "teams in orange" that led with the Packers would
    # be wrong to every person who looked at it.
    ("red", 345, 15), ("orange", 15, 36), ("gold", 36, 70), ("green", 70, 165),
    ("teal", 165, 195), ("blue", 195, 255), ("purple", 255, 290), ("pink", 290, 345),
)


def color_family(hex_color: str) -> str:
    """A hex colour to the family a person would name it. "" when it is unparseable, or so
    desaturated/dark that no hue name is honest (black, white, and the greys that several
    clubs genuinely use as a primary)."""
    text = (hex_color or "").strip().lstrip("#")
    if len(text) != 6:
        return ""
    try:
        r, g, b = (int(text[i:i + 2], 16) / 255 for i in (0, 2, 4))
    except ValueError:
        return ""
    hi, lo = max(r, g, b), min(r, g, b)
    delta = hi - lo
    if delta < 0.12:                       # grey axis: black, white, silver
        return "white" if hi > 0.75 else ("black" if hi < 0.25 else "grey")
    if hi == r:
        hue = 60 * (((g - b) / delta) % 6)
    elif hi == g:
        hue = 60 * (((b - r) / delta) + 2)
    else:
        hue = 60 * (((r - g) / delta) + 4)
    for name, start, end in _HUE_FAMILIES:
        if start > end:                    # the red wrap-around
            if hue >= start or hue < end:
                return name
        elif start <= hue < end:
            return name
    return ""


def merge_team_colors(seasons: list[RawSeason], teams: list[dict]) -> int:
    """Join `teams.primary_color` onto each row's `meta` as `color_family`, in place.

    Mirrors `main.merge_nfl_bio`'s posture exactly: best-effort, mutating the `meta` bag that
    exists for this, and silently leaving rows unjoined rather than failing a pull. Returns
    the number of rows enriched, so a caller can log coverage instead of guessing.
    """
    lookup: dict[tuple[str, str], str] = {}
    for row in teams:
        family = color_family(row.get("primary_color") or "")
        if family:
            lookup[(row.get("sport") or "", row.get("team_abbr") or "")] = family
    joined = 0
    for s in seasons:
        family = lookup.get((s.sport, s.team_abbr))
        if family:
            s.meta["color_family"] = family
            joined += 1
    return joined


def color_theme(sport: str, family: str, spec: curation.PositionSpec,
                slice_: curation.Slice | None = None) -> Theme:
    sl = slice_ or curation.Slice(key="all")
    label = "performances" if spec.grain == "game" else "seasons"
    return _spec_theme(
        f"shape-color-{sport}-{family}-{sl.key}".lower(),
        f"{sl.prefix}best {label} by a team in {family}{sl.suffix}",
        spec, sport, sl.filters + (Filter("color_family", "eq", family),),
    )


# ── Reaching the nightly mint ─────────────────────────────────────────────────
#
# Everything above is a library of builders. Without this section none of it ships: the
# nightly mint rolls `curation.SPORTS` cohorts and appends the curated list, and it has no
# idea these exist. `daily_shape_themes` is the bridge, and it is deliberately BOUNDED --
# `career_ladder_subjects` alone returns hundreds of players on a full catalogue, and building
# a board for each would cost more than the rest of the mint put together.

# How many subjects to try per shape, per sport, per run. Small on purpose: the point is that
# a shape board turns up regularly, not that every one of them is enumerated nightly.
SUBJECTS_PER_SHAPE = 3


def daily_shape_themes(seasons: list[RawSeason], rng, sport: str,
                       spec: curation.PositionSpec,
                       cross: curation.PositionSpec | None = None,
                       names: dict[str, str] | None = None) -> list[Theme]:
    """A handful of shape themes for one sport, subjects drawn at random from those the data
    can actually support.

    `spec` is the single-position cohort the ladders use; `cross` is the cross-positional one
    the roster board uses (rosters are interesting precisely because they mix positions).
    `names` maps abbreviations to readable club names (see `team_names`).
    """
    names = names or {}
    out: list[Theme] = []

    players = career_ladder_subjects(seasons, sport, spec.position_set, minimum=12)
    for player in _sample(players, SUBJECTS_PER_SHAPE, rng):
        out.append(career_ladder(sport, player, spec))

    if cross is not None:
        rosters = one_roster_subjects(seasons, sport, cross.position_set, minimum=12)
        for team, year in _sample(rosters, SUBJECTS_PER_SHAPE, rng):
            out.append(one_roster(sport, team, year, cross, display=names.get(team)))

    clubs = franchise_ladder_subjects(seasons, sport, spec.position_set,
                                      min_span=20, minimum=12)
    for club in _sample(clubs, SUBJECTS_PER_SHAPE, rng):
        out.append(franchise_ladder(sport, club, spec, display=names.get(club)))

    return out


def _sample(items: list, count: int, rng) -> list:
    """`count` distinct items, or all of them when there are fewer. Uses the caller's seeded
    rng so a day's mint stays reproducible."""
    if not items:
        return []
    return rng.sample(items, min(count, len(items)))
