"""The Grid: a 3x3 team x decade puzzle. Guarantees every cell has >=1 real, valid answer
(the same viability-gate philosophy as generate.py's _is_viable) -- picked deterministically
per (sport, date), retrying across seeded team/decade combos until one is fully viable.

Rarity v1 is offline-deterministic: a cell's rarity is derived purely from how many valid
answers exist for it at generation time (baked into content), not from live player guesses --
a server-side "X% of players guessed this" rarity is a deferred follow-up (see BALLIQ_SPEC.md).
"""
from __future__ import annotations

import itertools
import random
from dataclasses import dataclass

from .models import RawSeason, slug


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
    row_teams: tuple[str, str, str]
    col_decades: tuple[int, int, int]
    cells: tuple[GridCell, ...]   # length 9, row-major: cells[row*3 + col]

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


def _build_cell(pool: list[RawSeason], team: str, decade: int) -> GridCell | None:
    matches = [s for s in pool if s.team_abbr == team and _decade(s.season_year) == decade]
    # One answer per distinct player (their most recent qualifying season, for display).
    by_name: dict[str, RawSeason] = {}
    for s in matches:
        existing = by_name.get(s.name)
        if existing is None or s.season_year > existing.season_year:
            by_name[s.name] = s
    if not by_name:
        return None
    answers = tuple(
        GridAnswer(player_id=slug(s.name), name=s.name, team_abbr=s.team_abbr, season_year=s.season_year)
        for s in sorted(by_name.values(), key=lambda s: s.name)
    )
    return GridCell(valid_answers=answers, rarity_stars=_rarity_stars(len(answers)))


def generate_grid(seasons: list[RawSeason], sport: str, date: str,
                  max_attempts: int = 200) -> GridPuzzle | None:
    """Deterministic per (sport, date). Tries successive seeded team/decade combos (drawn from
    what's actually present in `seasons`) until every one of the 9 cells has >=1 valid answer,
    or gives up after `max_attempts` (returns None -- caller skips today's Grid rather than
    shipping a broken puzzle, same posture as daily_puzzle.py's viability gate)."""
    pool = [s for s in seasons if s.sport == sport and not s.career]
    # A blank team_abbr is missing/unresolved data, not a real team -- never a valid row label.
    teams = sorted({s.team_abbr for s in pool if s.team_abbr})
    decades = sorted({_decade(s.season_year) for s in pool})
    if len(teams) < 3 or len(decades) < 3:
        return None

    for attempt in range(max_attempts):
        rng = random.Random(f"grid-{sport}-{date}-{attempt}")
        row_teams = tuple(rng.sample(teams, 3))
        col_decades = tuple(sorted(rng.sample(decades, 3)))
        cells: list[GridCell] = []
        viable = True
        for team, decade in itertools.product(row_teams, col_decades):
            cell = _build_cell(pool, team, decade)
            if cell is None:
                viable = False
                break
            cells.append(cell)
        if viable:
            return GridPuzzle(sport=sport, row_teams=row_teams, col_decades=col_decades,
                              cells=tuple(cells))
    return None


def to_content(puzzle: GridPuzzle) -> dict:
    """camelCase JSON content for the `puzzles` row (mirrors assemble.py's convention -- the
    Swift Codable models decode camelCase). `sport` is baked into content itself (not just the
    row's own `sport` column), matching assemble.py's keep4/whoami rows -- the Swift
    `GridPuzzle` model decodes it from `content`, same as `Keep4Puzzle`/`WhoAmIPuzzle` do."""
    return {
        "sport": puzzle.sport,
        "rowTeams": list(puzzle.row_teams),
        "colDecades": list(puzzle.col_decades),
        "cells": [
            {
                "validAnswerIds": [a.player_id for a in cell.valid_answers],
                "validAnswerNames": [a.name for a in cell.valid_answers],
                "rarityStars": cell.rarity_stars,
            }
            for cell in puzzle.cells
        ],
    }


def puzzle_id(sport: str, date: str) -> str:
    return f"grid-{sport}-{date}"
