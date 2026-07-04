"""Assemble graded real seasons into puzzle rows in the exact camelCase shape the
Swift Codable models decode (Keep4Puzzle / WhoAmIPuzzle).

A "row" mirrors the `puzzles` table: {id, sport, format, content, active_date}.
`content` is the JSON the app reads.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

from .grade import BaselineTable, grade, grade_era
from .models import RawSeason, WhoAmIEntry, slug
from .themes import Theme, format_columns

KEEP_COUNT = 8


@dataclass
class PuzzleRow:
    id: str
    sport: str
    format: str          # 'keep4' | 'whoami'
    content: dict
    active_date: str | None = None


# ── Keep4 ─────────────────────────────────────────────────────────────────────

def _player_content(theme: Theme, season: RawSeason, value: float) -> dict:
    content = {
        "id": season.player_id,
        "name": season.name,
        "teamAbbr": season.team_abbr,
        "seasonYear": season.season_year,
        "grade": value,
        "stats": format_columns(theme, season.stats, season.position),
    }
    if season.headshot:
        content["headshot"] = season.headshot
    if season.week is not None:        # game-grain card context (Swift renders "vs OPP · Wk W")
        content["week"] = season.week
        content["opponent"] = season.opponent
    if season.career:                  # career-grain card context (Swift renders "CAREER · 1996-2016")
        content["firstYear"] = int(season.meta.get("first_year", season.season_year))
        content["lastYear"] = int(season.meta.get("last_year", season.season_year))
    return content


def grade_pool(theme: Theme, seasons: list[RawSeason],
               baselines: BaselineTable | None = None) -> list[tuple[RawSeason, float]]:
    """Filter `seasons` to the theme and grade them, best-first.

    Dedupes by *person* (keeps each player's single best graded season) so the
    same star can't appear twice in one puzzle, then caps to the candidate pool.
    Era-adjusted themes grade via `grade_era` (raw points × era volume index);
    `baselines` must be provided for them.
    """
    use_era = theme.era_adjusted and baselines is not None
    graded: dict[str, tuple[RawSeason, float]] = {}
    for s in seasons:
        if s.sport != theme.sport or s.position not in theme.positions:
            continue
        # Keep season/game/career pools strictly separate — a career row has week=None
        # just like a season row, so this can't collapse to a single boolean check.
        s_grain = "career" if s.career else ("game" if s.week is not None else "season")
        if s_grain != theme.grain:
            continue
        if any(s.stats.get(k, 0.0) < v for k, v in theme.min_stats.items()):
            continue
        if not all(f.matches(s) for f in theme.filters):
            continue
        g = (grade_era(s.stats, theme.scale, s.sport, s.position, s.season_year, baselines)
             if use_era else grade(s.stats, theme.scale))
        person = slug(s.name)
        prev = graded.get(person)
        if prev is None or g > prev[1]:
            graded[person] = (s, g)
    ranked = sorted(graded.values(), key=lambda t: (-t[1], slug(t[0].name)))
    return ranked[: theme.pool_cap]


def _windows(ranked: list[tuple[RawSeason, float]], max_variants: int) -> list[list[tuple[RawSeason, float]]]:
    """Contiguous 8-season windows clustered in grade, with an unambiguous
    top-4/bottom-4 split (grade[3] != grade[4]). Evenly sampled for variety."""
    n = len(ranked)
    if n < KEEP_COUNT:
        return []
    candidates = []
    for i in range(n - KEEP_COUNT + 1):
        win = ranked[i:i + KEEP_COUNT]
        if win[3][1] != win[4][1]:           # clean keep/cut boundary
            candidates.append(win)
    if not candidates:
        return []
    if len(candidates) <= max_variants:
        return candidates
    step = (len(candidates) - 1) / (max_variants - 1) if max_variants > 1 else 0
    return [candidates[round(k * step)] for k in range(max_variants)]


def build_keep4_rows(theme: Theme, seasons: list[RawSeason],
                     baselines: BaselineTable | None = None) -> list[PuzzleRow]:
    ranked = grade_pool(theme, seasons, baselines)
    rows: list[PuzzleRow] = []
    for variant, window in enumerate(_windows(ranked, theme.max_variants)):
        # Store players in a stable, non-grade order so the JSON doesn't leak the answer.
        players = sorted(
            (_player_content(theme, s, g) for s, g in window),
            key=lambda p: p["id"],
        )
        row_id = f"{theme.key}-{variant:02d}"
        content = {
            "id": row_id,
            "theme": theme.title,
            "sport": theme.sport,
            "players": players,
            "grain": theme.grain,
        }
        rows.append(PuzzleRow(id=row_id, sport=theme.sport, format="keep4", content=content))
    return rows


# ── Who Am I? ─────────────────────────────────────────────────────────────────

def _clue(order: int, kind: str, text: str) -> dict:
    return {"order": order, "kind": kind, "text": text}


def _jersey_text(jersey: str) -> str:
    plural = any(sep in jersey for sep in (",", "and", "&", "/"))
    return f"Wore number{'s' if plural else ''} {jersey}"


def build_whoami_row(entry: WhoAmIEntry) -> PuzzleRow:
    era = (
        f"Played from {entry.first_year} to {entry.last_year}"
        if entry.last_year != entry.first_year
        else f"Played in {entry.first_year}"
    )
    clues = [
        _clue(1, "era", era),
        _clue(2, "position", entry.position),
        _clue(3, "teams", ", ".join(entry.teams)),
        _clue(4, "statLine", entry.stat_line),
        _clue(5, "fact", entry.fact),
        _clue(6, "jersey", _jersey_text(entry.jersey)),
    ]
    row_id = f"{entry.sport}-whoami-{slug(entry.canonical)}"
    content = {
        "id": row_id,
        "sport": entry.sport,
        "clues": clues,
        "answer": {"canonical": entry.canonical, "aliases": entry.aliases},
    }
    return PuzzleRow(id=row_id, sport=entry.sport, format="whoami", content=content)


def load_whoami_entries(path) -> list[WhoAmIEntry]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return [WhoAmIEntry(**e) for e in raw]
