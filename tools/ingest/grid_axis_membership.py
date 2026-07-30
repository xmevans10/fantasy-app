"""Materialise which (player, season) pairs satisfy each stat and position axis.

The client generates its own Grid practice boards (`GridLocalGenerator.swift`) from the
membership index that `grid_membership_index` serves. Team and decade axes fall straight out of
the player -> (team, year) relation 0011 already ships, but stat and position axes do not: they
need someone to actually evaluate "did this season clear 1,000 rushing yards", and the client has
neither the stat values nor the thresholds.

**This module is deliberately thin, and that is the point.** It does not know what an axis is or
where a threshold comes from — it asks `grid_axes` for the same `GridAxis` objects `grid.py`
builds daily boards from, and evaluates the same `Filter` predicates through the same
`axis.matches`. Nothing here restates a threshold, so the practice board and the ranked daily
board can never drift into asking different questions under the same label. Re-expressing the
predicates in SQL (the obvious alternative, since the output is a table) is exactly the drift this
avoids: see the header of supabase/migrations/0012.

Season grain only. Every stat and position axis in `grid_axes` is season-grain, and the wire
format keys rows by `(player_name, season_year)` to match. Career-grain stat axes ("10,000+
Career Passing Yards") are a separate roadmap item and would need a different row shape, not a
reinterpretation of these.
"""
from __future__ import annotations

from .grid_axes import LEAGUE_SCOPED_SPORTS, GridAxis, position_axes, stat_axes
from .models import RawSeason


def axes_for(sport: str) -> list[GridAxis]:
    """Every non-team, non-decade axis this sport can offer — the ones a client cannot derive
    from the membership relation on its own. Decades are deliberately absent: they are a pure
    function of `season_year`, which the client already has, so shipping them would be payload
    restating something it can compute."""
    return stat_axes(sport) + position_axes(sport)


def membership_rows(seasons: list[RawSeason], sport: str) -> list[dict]:
    """`grid_axis_membership` rows for one sport.

    **The team is carried from the SAME row that satisfied the axis, and that is the whole point
    of this shape.** A first version stored only (axis, player, year) and let the client join it
    against the team relation on the year — which silently answers a different question, because
    `player_seasons` is game-grain and also carries teamless season-aggregate rows for players who
    moved mid-season. James Harden has 7 CLE rows for 2026 and 3 rows with a blank `team_abbr`;
    the aggregate row is what clears "8+ APG", so a year-join concluded he cleared 8 APG *as a
    Cavalier*, which `grid.py` (matching both predicates against one `RawSeason`) correctly
    denies. The cross-check caught it — see `GridCrossCheckTests`.

    Blank-team rows are kept, not dropped: they are exactly what a CAREER-grain axis question
    ("cleared 8 APG in some season") should still count, and `grid.py` counts them there too.
    Only the season-grain (axis x team) pairing needs a real team, which is a read-side concern.

    Deduplicated on (axis, player, team, year) because game-grain rows would otherwise repeat a
    single fact dozens of times.
    """
    pool = [s for s in seasons if s.sport == sport and not s.career]
    league_scoped = sport in LEAGUE_SCOPED_SPORTS
    seen: set[tuple[str, str, str, str, int]] = set()
    rows: list[dict] = []
    for axis in axes_for(sport):
        for season in pool:
            if not season.name or season.season_year is None:
                continue
            if not axis.matches(season):
                continue
            team = season.team_abbr or ""
            league = (season.meta.get("league", "") or "") if league_scoped else ""
            key = (axis.key, season.name, team, league, season.season_year)
            if key in seen:
                continue
            seen.add(key)
            rows.append({
                "sport": sport,
                "axis_key": axis.key,
                "axis_kind": axis.kind,
                "axis_label": axis.label,
                "player_name": season.name,
                "team_abbr": team,
                "league": league,
                "season_year": season.season_year,
            })
    return rows
