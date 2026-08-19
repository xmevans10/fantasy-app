"""Lightweight shape validation for puzzle `content` before upsert.

Catches drift from the Swift Codable models (Keep4Puzzle / WhoAmIPuzzle / JourneymanPuzzle)
early, so a malformed row never reaches the table.
"""
from __future__ import annotations

import re

from .assemble import KEEP_COUNT, PuzzleRow
from .whoami_clues import CLUE_COUNT, DIFFICULTIES

# The six `ClueKind` raw values the shipped App Store build can decode. This set is a
# **wire-compatibility contract, not a list of clue types** — the clue library has ~30
# dimensions and maps every one of them onto a value in here, because an unrecognized
# kind fails `WhoAmIPuzzle`'s decode on older clients and drops them to the bundled pool.
# See tools/ingest/whoami_clues.py's module docstring before adding to this set.
_VALID_KINDS = {"era", "position", "teams", "statLine", "fact", "jersey"}
_VALID_SPORTS = {"nfl", "nba", "baseball", "soccer", "tennis"}


def validate(row: PuzzleRow) -> None:
    if row.sport not in _VALID_SPORTS:
        raise ValueError(f"{row.id}: bad sport {row.sport!r}")
    if row.format == "keep4":
        _validate_keep4(row)
    elif row.format == "whoami":
        _validate_whoami(row)
    elif row.format == "journeyman":
        _validate_journeyman(row)
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


def _validate_journeyman(row: PuzzleRow) -> None:
    from .journeyman import MAX_STINTS, MIN_STINTS

    c = row.content
    stints = c.get("stints", [])
    floor = MIN_STINTS.get(row.sport, 2)
    if not floor <= len(stints) <= MAX_STINTS:
        raise ValueError(f"{row.id}: expected {floor}-{MAX_STINTS} stints, got {len(stints)}")
    if [s["order"] for s in stints] != list(range(1, len(stints) + 1)):
        raise ValueError(f"{row.id}: stint orders must be 1..{len(stints)}")
    previous_last = None
    for s in stints:
        for field in ("teamAbbr", "teamName", "firstYear", "lastYear"):
            if not s.get(field):
                raise ValueError(f"{row.id}: stint {s['order']} missing {field}")
        if s["firstYear"] > s["lastYear"]:
            raise ValueError(f"{row.id}: stint {s['order']} ends before it starts")
        # Chronological is the whole board — an out-of-order path would read as a career the
        # player never had, and the client renders `stints` in exactly the order it receives.
        if previous_last is not None and s["firstYear"] < previous_last:
            raise ValueError(f"{row.id}: stint {s['order']} starts before the previous ends")
        previous_last = s["lastYear"]
    # A club repeated back-to-back means the run-length encoding failed, which would show the
    # player leaving a club to join the same club. Keyed on the displayed NAME, not the code:
    # one franchise can arrive under several codes (OAK/LV), and one code can legitimately name
    # two clubs in a row across a rebrand (TEN: Oilers then Titans).
    for a, b in zip(stints, stints[1:]):
        if a["teamName"] == b["teamName"] and (a.get("league") or "") == (b.get("league") or ""):
            raise ValueError(f"{row.id}: adjacent stints at the same club ({a['teamName']})")
    difficulty = c.get("difficulty")
    if difficulty not in DIFFICULTIES:
        raise ValueError(f"{row.id}: bad difficulty {difficulty!r}")
    answer = c.get("answer", {})
    if not answer.get("canonical"):
        raise ValueError(f"{row.id}: missing canonical answer")


def _validate_whoami(row: PuzzleRow) -> None:
    c = row.content
    clues = c.get("clues", [])
    if len(clues) != CLUE_COUNT:
        raise ValueError(f"{row.id}: expected {CLUE_COUNT} clues, got {len(clues)}")
    if [cl["order"] for cl in clues] != list(range(1, CLUE_COUNT + 1)):
        raise ValueError(f"{row.id}: clue orders must be 1..{CLUE_COUNT}")
    seen_dimensions: set[str] = set()
    for cl in clues:
        if cl["kind"] not in _VALID_KINDS:
            raise ValueError(f"{row.id}: bad clue kind {cl['kind']!r}")
        if not cl.get("text"):
            raise ValueError(f"{row.id}: empty clue text")
        # Randomized selection makes a repeat a live possibility rather than a theoretical
        # one — two identical clues on one card is the most visible way this can go wrong.
        dimension = cl.get("dimension")
        if dimension:
            if dimension in seen_dimensions:
                raise ValueError(f"{row.id}: duplicate clue dimension {dimension!r}")
            seen_dimensions.add(dimension)
        if not cl.get("label"):
            raise ValueError(f"{row.id}: clue {cl['order']} missing a display label")
    texts = [cl["text"] for cl in clues]
    if len(set(texts)) != len(texts):
        raise ValueError(f"{row.id}: duplicate clue text")
    difficulty = c.get("difficulty")
    if difficulty not in DIFFICULTIES:
        raise ValueError(f"{row.id}: bad difficulty {difficulty!r}")
    answer = c.get("answer", {})
    if not answer.get("canonical"):
        raise ValueError(f"{row.id}: missing canonical answer")
    # A clue that gives away the answer is the one unrecoverable content bug in this format,
    # and randomized text drawn from ~30 builders is exactly where it sneaks in. Checks every
    # name part, not just the surname: the nickname dimension is the live hazard here (Magic
    # Johnson's nickname *is* his listed first name, Larry Bird's is "Larry Legend"), and a
    # first-name leak spoils a puzzle just as thoroughly as a last-name one.
    #
    # Parts under 4 characters are skipped — "Jr", "Sr", "de", "Le" are not tells, and short
    # fragments collide with ordinary clue words often enough to be useless as a signal.
    # Whole words only. A bare substring test is not usable here: it flagged the perfectly
    # innocent tennis clue "Competed for USA" as leaking "Pete" (Sampras), and short common
    # names are inside ordinary English words often enough that the check would either be
    # switched off or routinely overridden — neither of which catches a real leak.
    name_parts = [part.strip(".").lower() for part in answer["canonical"].split()]
    for cl in clues:
        text = cl["text"].lower()
        leaked = next((p for p in name_parts
                       if len(p) >= 4 and re.search(rf"\b{re.escape(p)}\b", text)), None)
        if leaked:
            raise ValueError(f"{row.id}: clue {cl['order']} leaks {leaked!r} "
                             f"from the answer: {cl['text']!r}")
