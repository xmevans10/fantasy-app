"""The Grid: a 3x3 board whose rows and columns are *axes* — a team, a decade, a position, or a
statistical milestone — rather than the fixed teams x decades it was until 2026-07-27.

Every board minted before that date had the identical shape: rows were three team abbreviations,
columns three decades, hardcoded from this generator through the content JSON to the SwiftUI
layout. The axis vocabulary now lives in `grid_axes.py`; this module picks axes and guarantees
viability. See docs/grid-axes-research.md for the Immaculate Grid research this follows, and
`grid_axes`'s module docstring for the grain model (which season has to satisfy which axis) —
that part is subtle and is the reason team x team boards are possible at all.

Guarantees kept from the original: every cell has >=1 real, valid answer (the same viability-gate
philosophy as generate.py's `_is_viable`), and generation is deterministic per (sport, date),
retrying across seeded combinations until one is fully viable.

Rarity v1 is still offline-deterministic: a cell's rarity is derived purely from how many valid
answers exist for it at generation time (baked into content), not from live player guesses -- a
server-side "X% of players guessed this" rarity is a deferred follow-up (see BALLIQ_SPEC.md).
"""
from __future__ import annotations

import itertools
import math
import random
from dataclasses import dataclass

from .grid_axes import (LEAGUE_SCOPED_SPORTS, TEAM_MOBILE_SPORTS, GridAxis, decade_axis,
                        position_axes, stat_axes, team_axis)
from .models import RawSeason, slug

# Trailing window (days) of `grid_history` combos a fresh board must not repeat. Modest by
# design: long enough that a verbatim repeat feels impossible in play, short enough that even a
# small sport's combo space can't be exhausted by the rejection set.
GRID_HISTORY_WINDOW_DAYS = 60

# Content schema version baked into every board. v1 was the implicit teams x decades shape
# (`rowTeams`/`colDecades`); v2 is the symmetric `rows`/`cols` axis lists. The client decodes
# both -- a v1 board already minted must keep playing correctly, since a live board is immutable
# for its day and players may be mid-grid when a new build ships.
CONTENT_VERSION = 2

# How many teams a team x team board may draw from, ranked by how many distinct players they
# have. Two randomly-chosen clubs out of soccer's 961 almost never share a player, so an
# unrestricted draw would burn every attempt on unviable boards; capping to the most-represented
# franchises makes the pairing both viable and recognisable (Immaculate Grid likewise builds
# team x team boards out of major franchises, not the long tail).
TEAM_X_TEAM_POOL = 60

# Upper bound on a cell's GRADED answers. The floor (>=1, in `_build_cell`) has always been
# there; this is its missing other half, and without it "too easy" was a quantity the generator
# could not express at all — `_rarity_stars` flattens everything from 15 answers upward into a
# single 1-star bucket, so a 40-answer cell and a 4,000-answer cell were literally the same
# value to it.
#
# That gap is why board *shape* was doing a job that belongs to cell *size*. `decades-x-stats`
# was pulled after a dry run produced soccer cells like "2010s x 10+ Assists" (765 players), and
# the fix generalised to "every cell must cross a team" — which also threw out NFL's
# "1990s x 30+ Pass TD" at 44 players, tighter than the "DAL x 2000s" (78) that ships today.
# Measured directly against the live catalog rather than argued from shape.
#
# Graded hits only, deliberately: roster extras widen validity without being the "how many
# notable answers exist" signal (same reason `_rarity_stars` reads graded hits), so counting
# them would reject NFL team cells for the roster coverage that is the point of having them.
#
# 200 is measured, not chosen. Sweeping every archetype's candidate cells against the live
# catalog (graded answers per cell, per sport):
#
#   teams-x-teams        baseball  med 156  p90 209  max 1102   <- the binding constraint
#   teams-x-mixed        baseball  med  36  p90 431  max  590
#   teams-x-decades      baseball  med  80  p90 101  max  129
#   decades-x-stats      nfl       med  30  p90  67  max   92
#   decades-x-stats      soccer    med 302  p90 1780 max 4959   <- what must not survive
#   positions-x-decades  soccer    med 2276 p90 4678 max 5011
#
# The floor is set by career-grain team x team, whose cells are legitimately large — "played for
# both the Yankees and the Red Sox" across 150 years really is ~156 players, and that is the
# single most recognisable cell the format has. The ceiling is set by soccer's decade x stat at
# 302. Those two bracket a narrow window, and 200 is inside it: every shape that ships today
# survives, soccer's decade x stat dies on its own numbers, and baseball's "NYY x Hitters"
# (p90 431 on teams-x-mixed) is rejected as a bonus — a weak cell the old shape rule waved
# through, because a team dimension was assumed sufficient rather than measured.
#
# positions-x-decades stays out of ARCHETYPES: at a median of 2,276 it is not a near miss that
# a ceiling could rescue, and the ceiling would reject every board it ever proposed.
MAX_CELL_ANSWERS = 200


@dataclass(frozen=True)
class GridAnswer:
    player_id: str
    name: str
    team_abbr: str
    season_year: int


@dataclass(frozen=True)
class GridCell:
    valid_answers: tuple[GridAnswer, ...]
    rarity_stars: int   # 1 (common) .. 5 (rarest)


@dataclass(frozen=True)
class GridPuzzle:
    sport: str
    rows: tuple[GridAxis, ...]
    cols: tuple[GridAxis, ...]
    cells: tuple[GridCell, ...]   # length 9, row-major: cells[row*3 + col]
    archetype: str = ""           # which board shape produced this, for history/telemetry

    def cell(self, row: int, col: int) -> GridCell:
        return self.cells[row * 3 + col]


def _decade(year: int) -> int:
    return (year // 10) * 10


def _rarity_stars(count: int) -> int:
    """1 (common, 15+ valid answers) .. 5 (rarest, exactly 1)."""
    if count <= 1:
        return 5
    if count <= 3:
        return 4
    if count <= 7:
        return 3
    if count <= 14:
        return 2
    return 1


def _group_by_player(pool: list[RawSeason]) -> dict[str, list[RawSeason]]:
    """Seasons keyed by player name. Grouping once up front (rather than per cell, as the
    teams x decades version did) is what makes career-grain axes cheap: "did this player ever
    play for X" is a scan of one already-materialised list."""
    by_player: dict[str, list[RawSeason]] = {}
    for season in pool:
        by_player.setdefault(season.name, []).append(season)
    return by_player


def _satisfying_season(seasons: list[RawSeason], row: GridAxis, col: GridAxis) -> RawSeason | None:
    """The season to display for a player who satisfies this cell, or None if they don't.

    Implements the grain rule documented in `grid_axes`: every `season`-grain axis must be
    satisfied by ONE common season, while each `career`-grain axis may be satisfied by any season
    in the player's history. That is Immaculate Grid's own rule -- "1,000 yards *as a Bear*" is
    one season, "played for both" is not.
    """
    axes = (row, col)
    for axis in axes:
        if axis.grain == "career" and not any(axis.matches(s) for s in seasons):
            return None
    season_axes = [a for a in axes if a.grain == "season"]
    candidates = [s for s in seasons if all(a.matches(s) for a in season_axes)]
    if season_axes and not candidates:
        return None
    # Most recent qualifying season, for display -- matches the original's per-player choice.
    return max(candidates or seasons, key=lambda s: s.season_year)


def _build_cell(by_player: dict[str, list[RawSeason]], row: GridAxis, col: GridAxis,
                extra_by_player: dict[str, list[RawSeason]] | None = None) -> GridCell | None:
    graded_hits: dict[str, RawSeason] = {}
    for name, seasons in by_player.items():
        hit = _satisfying_season(seasons, row, col)
        if hit is not None:
            graded_hits[name] = hit
    # Both bounds, same posture: a cell nobody can answer and a cell anybody can answer are
    # equally unfit, and either one sends `generate_grid` to the next seeded combination.
    if not graded_hits or len(graded_hits) > MAX_CELL_ANSWERS:
        return None
    # Rarity stars come from the GRADED pool only -- that's the stable "how many notable answers
    # exist" signal the star economy was tuned on. Roster extras (below) widen *validity* without
    # inflating every cell to 1-star.
    stars = _rarity_stars(len(graded_hits))
    graded = [
        GridAnswer(player_id=slug(s.name), name=s.name, team_abbr=s.team_abbr,
                   season_year=s.season_year)
        for s in graded_hits.values()
    ]
    # Full-roster members (nfl_rosters.py) matching this cell, minus players the graded pool
    # already covers. Validity-only: they never affect stars, and never create viability -- a
    # cell with zero graded answers stays None. They carry no stats, so they can only ever
    # satisfy team/decade/position axes; a stat axis rejects them automatically via `Filter`,
    # which is exactly right (we can't assert a roster-only player hit 1,000 yards).
    extras: list[GridAnswer] = []
    for name, seasons in (extra_by_player or {}).items():
        if name in graded_hits:
            continue
        hit = _satisfying_season(seasons, row, col)
        if hit is not None:
            extras.append(GridAnswer(player_id=slug(hit.name), name=hit.name,
                                     team_abbr=hit.team_abbr, season_year=hit.season_year))
    answers = tuple(sorted(graded + extras, key=lambda a: a.name))
    return GridCell(valid_answers=answers, rarity_stars=stars)


def combo_key(rows: tuple[GridAxis, ...], cols: tuple[GridAxis, ...]) -> tuple[str, str]:
    """Canonical, order-independent identity of a board's axis sets — the shape stored in
    `grid_history` (still the `row_teams`/`col_decades` text columns, whose names are now
    historical) and matched against by `generate_grid`'s recently-served rejection."""
    return ("|".join(sorted(a.key for a in rows)), "|".join(sorted(a.key for a in cols)))


# MARK: - Board archetypes

@dataclass(frozen=True)
class Archetype:
    """A coherent board shape. Archetypes exist instead of free-form axis mixing because the
    grain rules make arbitrary pairings hard to reason about (a career-grain team axis crossed
    with a decade axis would accept "played for KC in 2010, played *somewhere* in the 1980s" —
    technically satisfiable, but not the question the board appears to ask). Each archetype
    fixes the semantics of both dimensions, so every cell it produces asks something coherent.
    """

    key: str
    rows: str          # 'team' | 'team_career' | 'decade' | 'position' | 'stat'
    cols: str
    weight: int        # relative frequency in the rotation


ARCHETYPES: tuple[Archetype, ...] = (
    # The original shape, kept in rotation — it's a good board, it was just the *only* board.
    Archetype("teams-x-decades", "team", "decade", weight=3),
    Archetype("teams-x-stats", "team", "stat", weight=4),
    Archetype("teams-x-teams", "team_career", "team_career", weight=3),
    Archetype("teams-x-mixed", "team", "mixed", weight=4),
    # The one shape where a single dimension is heterogeneous *including* teams: a left edge
    # reading "MIA / 30+ Pass TD / 1980s" against three team columns. Every other archetype
    # fixes one kind per dimension, so until this one the rows were always teams and only the
    # columns ever varied. `mixed_any` is legal ONLY opposite an all-team dimension — that's
    # what keeps every cell team-anchored (see below) even though the row kinds vary.
    Archetype("mixed-x-teams", "mixed_any", "team_career", weight=3),
    # The one shape with no team on either side. Pulled in the first pass and readmitted once
    # `MAX_CELL_ANSWERS` existed to judge it on the thing that actually went wrong (cell size)
    # rather than on shape: "1990s x 30+ Pass TD" is 44 players, tighter than the "DAL x 2000s"
    # that ships today, while the soccer cells that got it pulled ("2010s x 10+ Assists", 765)
    # now fail the ceiling on their own. Weight 2, the lowest in the rotation — it is the least
    # proven shape and the only one whose viability varies this sharply by sport, so it earns a
    # smaller share until real boards back it up.
    Archetype("decades-x-stats", "decade", "stat", weight=2),
)

# EVERY CELL must be SPECIFIC — few enough valid answers that it asks "name the player who
# connects these two facts" rather than "name any midfielder". That is the product rule, and
# `MAX_CELL_ANSWERS` is now what enforces it, per cell, on measured data.
#
# It used to be enforced as "every cell must cross a team", which is a different claim: it is a
# proxy for specificity, and a lossy one in both directions. It threw out cells that are
# perfectly tight ("1990s x 30+ Pass TD", 44 players — tighter than the "DAL x 2000s" at 78 that
# ships daily), and it silently blessed loose ones, since a team dimension was *assumed*
# sufficient rather than checked (nothing stopped a soccer teams x stats board from carrying a
# 700-answer cell). Measuring the cell replaces both failure modes with one honest test.
#
# Worth keeping in mind if a future shape tempts you back toward structural rules: the reason
# "one whole side is teams" appeared inevitable is that it IS forced by a per-cell anchor rule —
# if any row is a non-team, every column must be a team, and vice versa, so no diagonal
# arrangement exists. That was sound reasoning from an unsound premise.
TEAM_DIMENSIONS = frozenset({"team", "team_career"})
# Dimensions whose kinds vary per axis. `mixed_any` still may only face an all-team dimension —
# not for anchoring now, but for identity: two heterogeneous dimensions produce boards with no
# describable shape, and an all-team opposite is what keeps `mixed-x-teams` legible as "these
# three things, against these three clubs" (`test_mixed_any_only_faces_a_team_dimension`).
HETEROGENEOUS_DIMENSIONS = frozenset({"mixed", "mixed_any"})


def _axis_pool(dimension: str, sport: str, pool: list[RawSeason],
               teams: list[tuple[str, str]], decades: list[int]) -> list[GridAxis]:
    """Candidate axes for one dimension of one archetype, or [] when this sport can't offer
    enough of them (fewer than 3 → the archetype is skipped rather than producing a short board).

    `teams` is a list of (abbr, league) pairs, not bare abbreviations — see `_team_keys`.
    """
    if dimension == "team":
        return [team_axis(abbr, league=league) for abbr, league in teams]
    if dimension == "team_career":
        if sport not in TEAM_MOBILE_SPORTS:
            return []
        return [team_axis(abbr, league=league, grain="career")
                for abbr, league in _prominent_teams(pool, teams)]
    if dimension == "decade":
        return [decade_axis(d) for d in decades]
    if dimension == "position":
        return position_axes(sport)
    if dimension == "stat":
        return stat_axes(sport)
    if dimension == "mixed":
        # One dimension drawing from every non-team kind at once — the shape that produces a
        # board like "KC / DAL / SEA" x "1980s / 30+ Pass TD / RB". This is where positions earn
        # their place: "Chiefs x RB" alone is a weak cell, but as one column of three varied
        # constraints it reads as a change of pace rather than the whole board's premise.
        return position_axes(sport) + stat_axes(sport) + [decade_axis(d) for d in decades]
    if dimension == "mixed_any":
        # `mixed`, plus teams — the only pool where a single dimension can hold a team on one
        # axis and a stat or decade on the next. Teams here take *career* grain to match the
        # all-team dimension opposite (which is `team_career`): a season-grain team crossed with
        # a career-grain team asks "same club the same year", a different and much emptier
        # question than "played for both" — the same grain reasoning that makes team x team work
        # at all (see grid_axes' module docstring).
        if sport not in TEAM_MOBILE_SPORTS:
            return []
        team_pool = [team_axis(abbr, league=league, grain="career")
                     for abbr, league in _prominent_teams(pool, teams)]
        return team_pool + position_axes(sport) + stat_axes(sport) + [decade_axis(d) for d in decades]
    raise ValueError(f"unknown axis dimension {dimension!r}")


def _team_key(season: RawSeason, league_scoped: bool) -> tuple[str, str]:
    """A franchise's identity within one sport: the abbreviation alone for the US sports, or
    (abbreviation, league) where codes collide across countries — see
    `grid_axes.LEAGUE_SCOPED_SPORTS`."""
    return (season.team_abbr, season.meta.get("league", "") if league_scoped else "")


def _team_keys(pool: list[RawSeason], league_scoped: bool) -> list[tuple[str, str]]:
    """Every distinct franchise in `pool`, as (abbr, league) pairs.

    A blank team_abbr is missing/unresolved data, not a real team — never a valid axis label.
    A blank *league* under a league-scoped sport is dropped for the same reason: an axis with no
    league filter would match every club sharing that code, which is exactly the merging this
    scoping exists to prevent.
    """
    keys = {_team_key(s, league_scoped) for s in pool if s.team_abbr}
    if league_scoped:
        keys = {k for k in keys if k[1]}
    return sorted(keys)


def _prominent_teams(pool: list[RawSeason],
                     teams: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Teams ranked by distinct player count, capped at `TEAM_X_TEAM_POOL`. Sorted by
    (-count, key) so the result is deterministic under ties rather than dict-order dependent."""
    league_scoped = any(league for _, league in teams)
    counts: dict[tuple[str, str], set[str]] = {}
    for season in pool:
        if season.team_abbr:
            counts.setdefault(_team_key(season, league_scoped), set()).add(season.name)
    ranked = sorted(teams, key=lambda t: (-len(counts.get(t, set())), t))
    return ranked[:TEAM_X_TEAM_POOL]


def _combo_space(row_pool: list[GridAxis], col_pool: list[GridAxis]) -> int:
    """How many distinct boards a shape could ever produce for this sport: C(rows,3) x C(cols,3).

    A shape whose entire space is smaller than the `grid_history` no-repeat window cannot sustain
    a rotation slot — it runs out of unseen boards inside the window and then burns attempts
    being rejected. Worse, a dimension with exactly 3 axes has no choice to make at all: every
    board it produces carries the *same three* labels.

    Tennis is the case that found this. It has exactly three stat axes, so `decades-x-stats`
    spans C(7,3) x C(3,3) = 35 boards, all with identical columns — and it took 20 of 21 days in
    a dry run, because it is reliably viable while tennis's richer shapes often aren't. Viable
    and varied are different properties, and only the first was being checked.
    """
    return math.comb(len(row_pool), 3) * math.comb(len(col_pool), 3)


def _is_varied(dimension: str, axes: tuple[GridAxis, ...]) -> bool:
    """Whether `axes` satisfy `dimension`'s variety requirement. Only `mixed_any` has one.

    Deliberately NOT applied to `mixed`. Both dimensions vary their kinds, but only `mixed_any`
    can contain a *team*, and a team is the kind that makes an all-same draw indistinguishable
    from an existing archetype (all-team rows on a mixed-x-teams board is just teams-x-teams).
    A `mixed` column that happens to draw three stats is merely a teams-x-stats-shaped board,
    which was always an accepted outcome — narrowing it here rejected viable boards for no gain
    and cost soccer a daily board outright.

    Floor is two distinct kinds, not three. Three ("a team, a stat and a decade" exactly) is the
    ideal this shape aims at, but requiring it would reject a lot of otherwise-viable boards for
    sports whose axis vocabulary is thin — and two already guarantees the dimension never
    silently collapses into a uniform one.
    """
    if dimension != "mixed_any":
        return True
    return len({a.kind for a in axes}) >= 2


def generate_grid(seasons: list[RawSeason], sport: str, date: str,
                  max_attempts: int = 500, extra_members: list | None = None,
                  recently_served: frozenset[tuple[str, str]] | set[tuple[str, str]] = frozenset(),
                  archetypes: tuple[Archetype, ...] | None = None,
                  ) -> GridPuzzle | None:
    """Deterministic per (sport, date). Tries successive seeded archetype + axis combinations
    (drawn from what's actually present in `seasons`) until every one of the 9 cells has >=1 valid
    answer, or gives up after `max_attempts` (returns None -- caller skips today's Grid rather
    than shipping a broken puzzle, same posture as daily_puzzle.py's viability gate).

    `max_attempts` is 500 rather than a token number because soccer is genuinely marginal: 961
    clubs, most of them obscure, so most team pairings share no player and a lot of draws are
    dead. Measured 2026-07-27: only 1,545 of soccer's 19,989 player-sharing club pairs share 5+
    players. It ran out at 200 and skipped a daily board outright, which is worse than the
    extra tries cost.

    `extra_members` (e.g. nfl_rosters.RosterMember) widen each cell's VALID answers to full
    rosters -- Immaculate-Grid-style "anyone who was on the team counts" -- without touching axis
    selection, viability, or rarity stars (all still graded-pool-driven).

    `recently_served` (combo_key tuples, from `grid_history`'s trailing window) is one more
    rejection condition in the same retry loop, so a fresh board can't repeat a recent axis-set
    verbatim. Deliberately lighter than Keep4's signature-level novelty -- determinism per
    `archetypes` overrides the default rotation — used by tests to pin a board shape, and by
    anyone wanting to preview a single shape from the CLI. Leave it None in production so the
    weighted rotation applies."""
    pool = [s for s in seasons if s.sport == sport and not s.career]
    if not pool:
        return None
    teams = _team_keys(pool, league_scoped=sport in LEAGUE_SCOPED_SPORTS)
    decades = sorted({_decade(s.season_year) for s in pool})
    # NOTE: there is deliberately no global "at least 3 teams AND 3 decades" precondition here.
    # That guard made sense when every board was teams x decades, but it now rejects boards that
    # use neither dimension — a teams x teams pool spanning one decade was returning None before
    # a single attempt ran. Sufficiency is checked per dimension inside the loop instead, against
    # the axes that board shape actually needs.

    by_player = _group_by_player(pool)
    extra_by_player = _group_by_player(_as_seasons(extra_members, sport)) if extra_members else None

    # Resolve each archetype's axis pools ONCE, and drop the shapes this sport can't offer
    # before the rotation is built rather than inside the retry loop.
    #
    # Doing this per-attempt was survivable while every sport could serve most shapes, but it
    # silently taxes the sports that can't: tennis has no `team_career` pool (it isn't in
    # TEAM_MOBILE_SPORTS), so both teams-x-teams and mixed-x-teams are impossible for it, and
    # each attempt that drew one burned a retry on a shape that could never work. Adding a fifth
    # archetype pushed that waste from 3/14 to 6/17 of attempts and started exhausting
    # max_attempts outright — tennis and soccer both went from a board to "no viable grid" on
    # 2026-07-27. Filtering up front makes the attempt budget buy only real candidates, and skips
    # recomputing `_prominent_teams` (a full scan of `pool`) up to 200 times.
    pools: dict[str, tuple[list[GridAxis], list[GridAxis]]] = {}
    feasible: list[Archetype] = []
    varied: list[Archetype] = []
    for candidate in (archetypes or ARCHETYPES):
        row_pool = _axis_pool(candidate.rows, sport, pool, teams, decades)
        col_pool = _axis_pool(candidate.cols, sport, pool, teams, decades)
        if len(row_pool) < 3 or len(col_pool) < 3:
            continue        # this sport can't offer this shape at all
        pools[candidate.key] = (row_pool, col_pool)
        feasible.append(candidate)
        if _combo_space(row_pool, col_pool) >= GRID_HISTORY_WINDOW_DAYS:
            varied.append(candidate)
    if not feasible:
        return None
    # Two tiers, tried in order: shapes with room to keep surprising (see `_combo_space`), then
    # everything feasible. A *preference*, never a filter, and the distinction is load-bearing in
    # both directions. `_combo_space` counts axes, not viable boards, so a shape can look rich and
    # still produce nothing — nfl stat axes exist for every sport whether or not the catalog has
    # the stats to satisfy them. Excluding thin shapes outright therefore risks dropping the only
    # one that actually works, which is exactly what a sparse-pool test caught. Falling through
    # guarantees this can only ever find a board where the old single-tier loop did, never fewer.
    for tier in ([varied, feasible] if varied and varied != feasible else [feasible]):
        # Weighted rotation, expanded once so a seeded `choice` picks by weight without
        # re-deriving the distribution on every attempt.
        rotation = [a for a in tier for _ in range(a.weight)]
        for attempt in range(max_attempts):
            rng = random.Random(f"grid-{sport}-{date}-{attempt}")
            archetype = rng.choice(rotation)
            row_pool, col_pool = pools[archetype.key]
            rows = tuple(rng.sample(row_pool, 3))
            cols = tuple(rng.sample(col_pool, 3))
            # Same-dimension pools can overlap across dimensions (teams x teams is the whole point
            # of that archetype) -- but a board with the SAME axis on a row and a column produces a
            # degenerate cell (e.g. "KC and KC"), so reject that.
            if {a.key for a in rows} & {a.key for a in cols}:
                continue
            # `mixed_any` has to actually be mixed. `rng.sample` draws uniformly from a pool that
            # mixes kinds in whatever proportion the sport happens to offer, so it lands on three
            # teams often enough to matter — and a mixed-x-teams board whose rows came out all-team
            # is just teams-x-teams wearing a different archetype label, which is exactly the
            # sameness this shape exists to break.
            if not _is_varied(archetype.rows, rows) or not _is_varied(archetype.cols, cols):
                continue
            if combo_key(rows, cols) in recently_served:
                continue
            cells: list[GridCell] = []
            viable = True
            for row, col in itertools.product(rows, cols):
                cell = _build_cell(by_player, row, col, extra_by_player=extra_by_player)
                if cell is None:
                    viable = False
                    break
                cells.append(cell)
            if viable:
                return GridPuzzle(sport=sport, rows=rows, cols=cols, cells=tuple(cells),
                                  archetype=archetype.key)
    return None


def _as_seasons(members: list | None, sport: str) -> list[RawSeason]:
    """Normalise roster memberships into `RawSeason`s so axis matching is uniform.

    `nfl_rosters.RosterMember` carries only (name, team_abbr, season_year) — no position, no
    stats — so the resulting rows satisfy team and decade axes and are correctly rejected by
    position and stat axes, which is the honest outcome: we can't assert a roster-only player was
    a QB or hit 1,000 yards. Members that are already `RawSeason`s pass through untouched.
    """
    out: list[RawSeason] = []
    for m in members or ():
        if isinstance(m, RawSeason):
            out.append(m)
            continue
        out.append(RawSeason(name=m.name, team_abbr=m.team_abbr, season_year=m.season_year,
                             sport=sport, position="", stats={}))
    return out


def to_content(puzzle: GridPuzzle) -> dict:
    """camelCase JSON content for the `puzzles` row (mirrors assemble.py's convention -- the
    Swift Codable models decode camelCase). `sport` is baked into content itself (not just the
    row's own `sport` column), matching assemble.py's keep4/whoami rows.

    Emits BOTH shapes on purpose. `rows`/`cols` is the real v2 payload; `rowTeams`/`colDecades`
    are also written whenever the board happens to be the classic teams x decades shape, so a
    client still running the pre-v2 decoder keeps working through the rollout instead of showing
    "No Grid today". They're dropped for any other archetype, where no honest v1 rendering
    exists -- an old client sees no board rather than a wrong one.
    """
    content: dict = {
        "sport": puzzle.sport,
        "version": CONTENT_VERSION,
        "archetype": puzzle.archetype,
        "rows": [_axis_content(a) for a in puzzle.rows],
        "cols": [_axis_content(a) for a in puzzle.cols],
        "cells": [
            {
                "validAnswerIds": [a.player_id for a in cell.valid_answers],
                "validAnswerNames": [a.name for a in cell.valid_answers],
                "rarityStars": cell.rarity_stars,
            }
            for cell in puzzle.cells
        ],
    }
    if all(a.kind == "team" and a.grain == "season" for a in puzzle.rows) and \
            all(a.kind == "decade" for a in puzzle.cols):
        content["rowTeams"] = [a.label for a in puzzle.rows]
        content["colDecades"] = [int(a.label.rstrip("s")) for a in puzzle.cols]
    return content


def _axis_content(axis: GridAxis) -> dict:
    """`kind` is what tells the client HOW to draw the label — a team axis gets the real crest +
    color chip, everything else is a text label. The filter predicates deliberately do NOT ship:
    the client never re-evaluates them (valid answers are baked per cell), so sending them would
    be dead weight and a second source of truth.

    `abbr`/`league` ship for team axes only, and `league` is why they ship at all: without it the
    client resolves "MCI" to whichever of Manchester City / Melbourne City its identity index
    happens to hit first, so a correct answer set would still render the wrong crest and colors.
    """
    out = {"kind": axis.kind, "label": axis.label, "grain": axis.grain, "key": axis.key}
    if axis.kind == "team":
        out["abbr"] = axis.abbr
        out["league"] = axis.league
    return out


def puzzle_id(sport: str, date: str) -> str:
    return f"grid-{sport}-{date}"
