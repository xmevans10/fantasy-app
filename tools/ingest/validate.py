"""Lightweight shape validation for puzzle `content` before upsert.

Catches drift from the Swift Codable models (Keep4Puzzle / WhoAmIPuzzle) early,
so a malformed row never reaches the table.
"""
from __future__ import annotations

from .assemble import KEEP_COUNT, PuzzleRow

_VALID_KINDS = {"era", "position", "teams", "statLine", "fact", "jersey"}
_VALID_SPORTS = {"nfl", "nba"}


def validate(row: PuzzleRow) -> None:
    if row.sport not in _VALID_SPORTS:
        raise ValueError(f"{row.id}: bad sport {row.sport!r}")
    if row.format == "keep4":
        _validate_keep4(row)
    elif row.format == "whoami":
        _validate_whoami(row)
    else:
        raise ValueError(f"{row.id}: bad format {row.format!r}")


def _validate_keep4(row: PuzzleRow) -> None:
    c = row.content
    players = c.get("players", [])
    if len(players) != KEEP_COUNT:
        raise ValueError(f"{row.id}: expected {KEEP_COUNT} players, got {len(players)}")
    if len({p["id"] for p in players}) != KEEP_COUNT:
        raise ValueError(f"{row.id}: duplicate player ids")
    grades = sorted((p["grade"] for p in players), reverse=True)
    if grades[3] == grades[4]:
        raise ValueError(f"{row.id}: ambiguous keep/cut boundary at grade {grades[3]}")
    for p in players:
        for field in ("id", "name", "teamAbbr", "seasonYear", "grade", "stats"):
            if field not in p:
                raise ValueError(f"{row.id}: player missing {field}")
        if not p["stats"]:
            raise ValueError(f"{row.id}: player {p['id']} has no stats")


def _validate_whoami(row: PuzzleRow) -> None:
    c = row.content
    clues = c.get("clues", [])
    if len(clues) != 6:
        raise ValueError(f"{row.id}: expected 6 clues, got {len(clues)}")
    if [cl["order"] for cl in clues] != [1, 2, 3, 4, 5, 6]:
        raise ValueError(f"{row.id}: clue orders must be 1..6")
    for cl in clues:
        if cl["kind"] not in _VALID_KINDS:
            raise ValueError(f"{row.id}: bad clue kind {cl['kind']!r}")
        if not cl.get("text"):
            raise ValueError(f"{row.id}: empty clue text")
    answer = c.get("answer", {})
    if not answer.get("canonical"):
        raise ValueError(f"{row.id}: missing canonical answer")
