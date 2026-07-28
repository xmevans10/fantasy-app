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

from .grid_axes import GridAxis, position_axes, stat_axes
from .models import RawSeason


def axes_for(sport: str) -> list[GridAxis]:
    """Every non-team, non-decade axis this sport can offer — the ones a client cannot derive
    from the membership relation on its own. Decades are deliberately absent: they are a pure
    function of `season_year`, which the client already has, so shipping them would be payload
    restating something it can compute."""
    return stat_axes(sport) + position_axes(sport)


def membership_rows(seasons: list[RawSeason], sport: str) -> list[dict]:
    """`grid_axis_membership` rows for one sport.

    Deduplicated on (axis, player, year) because `player_seasons` carries game-grain rows for
    some sports — the same reason 0011's relation is ~4x smaller than the table it comes from.
    A player satisfying an axis twice in one season is still one fact.
    """
    pool = [s for s in seasons if s.sport == sport and not s.career]
    seen: set[tuple[str, str, int]] = set()
    rows: list[dict] = []
    for axis in axes_for(sport):
        for season in pool:
            if not season.name or season.season_year is None:
                continue
            if not axis.matches(season):
                continue
            key = (axis.key, season.name, season.season_year)
            if key in seen:
                continue
            seen.add(key)
            rows.append({
                "sport": sport,
                "axis_key": axis.key,
                "axis_kind": axis.kind,
                "axis_label": axis.label,
                "player_name": season.name,
                "season_year": season.season_year,
            })
    return rows
