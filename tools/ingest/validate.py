"""Lightweight shape validation for puzzle `content` before upsert.

Catches drift from the Swift Codable models (Keep4Puzzle / WhoAmIPuzzle / JourneymanPuzzle)
early, so a malformed row never reaches the table.
"""
from __future__ import annotations

import re

from .assemble import KEEP_COUNT, PuzzleRow
from .whoami_clues import CLUE_COUNT, DIFFICULTIES, leaked_name_part

# The six `ClueKind` raw values the shipped App Store build can decode. This set is a
# **wire-compatibility contract, not a list of clue types** — the clue library has ~30
# dimensions and maps every one of them onto a value in here, because an unrecognized
# kind fails `WhoAmIPuzzle`'s decode on older clients and drops them to the bundled pool.
# See tools/ingest/whoami_clues.py's module docstring before adding to this set.
_VALID_KINDS = {"era", "position", "teams", "statLine", "fact", "jersey"}
_VALID_SPORTS = {"nfl", "nba", "baseball", "soccer", "tennis", "hockey", "f1"}

# Sports whose PUZZLES may be minted to the live `puzzles` table right now — a RELEASE gate,
# not a data gate. Everything in `_VALID_SPORTS` is real and fully ingested (catalog, teams,
# pools, Grid membership); this narrower set is about what shipped CLIENTS can decode.
#
# `Sport` on the client is a plain `String` raw-value enum with no unknown-case fallback, and
# the archive fetch has NO sport predicate when the user is on the "All" filter — it decodes
# the pool as an ARRAY under `try?`. So a single row carrying a sport an installed build has
# never heard of throws, the whole array returns nil, and that user's archive silently falls
# back to stale cache or the bundled JSON. Verified empirically 2026-09-06, and it is the exact
# hazard `_VALID_KINDS` above documents for `ClueKind` — same mechanism, different column.
#
# hockey/f1 (M31) are therefore ingested but NOT minted until a build whose `Sport` knows them
# is the floor in the wild. **To release them: add them here, then re-mint.** Nothing else
# needs changing — `daily_puzzle` and `run_grid` both read this.
WIRE_SAFE_SPORTS = {"nfl", "nba", "baseball", "soccer", "tennis"}


# Every headshot frozen into a board must come from OUR store, or be empty. Nothing else is
# acceptable on the wire, and this is the only place that can enforce it before a row ships.
#
# The bug it exists for (user-reported, 2026-09-06): a Journeyman board froze the raw
# `static.www.nfl.com` URL for Randall Cunningham, which is the league's GENERIC HELMET
# placeholder — it returns HTTP 200 with a real 382KB image, so no liveness check anywhere ever
# flagged it, and the reveal card showed a faceless helmet while a real photo of him sat in our
# Storage bucket the whole time. 247 live boards were in that state.
#
# Empty is allowed and is the correct value when we genuinely have no photo: the client draws
# its own neutral badge, which honestly reads as "no photo". A foreign URL is not allowed even
# when it resolves, because we cannot vouch for what is behind it.
HEADSHOT_STORE_MARKER = "/storage/v1/object/public/player-headshots/"


def _assert_headshots_are_ours(row_id: str, shots) -> None:
    for shot in shots:
        shot = (shot or "").strip()
        if shot and HEADSHOT_STORE_MARKER not in shot:
            raise ValueError(
                f"{row_id}: headshot is not from our store: {shot!r}. Boards must freeze a "
                f"rehosted URL (or ''), never a provider CDN link — see "
                f"main.apply_headshot_ledger and the `headshot_assets` ledger.")


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
    _assert_headshots_are_ours(row.id, (p.get("headshot") for p in players))
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
    _assert_headshots_are_ours(row.id, [c.get("headshot")])
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
    # The teaser is the archive card's title, so it leaks exactly as badly as a clue would.
    # Same word-boundary rule and the same >=4-character floor as `_validate_whoami` — see the
    # long note there for why a bare substring test is unusable.
    teaser = c.get("teaser")
    if teaser is not None:
        if not teaser.strip():
            raise ValueError(f"{row.id}: empty teaser")
        leaked = _leaked_name_part(answer["canonical"], teaser)
        if leaked:
            raise ValueError(f"{row.id}: teaser leaks {leaked!r} from the answer: {teaser!r}")
    # Hints are bought with points, so a broken one costs the player something real. Same leak
    # rule as the teaser (a nickname or a "known for" line routinely contains the surname), plus
    # the ordering contract the client indexes into: `hints[i]` is the (i+1)th rung of the
    # ladder, and its price is positional.
    hints = c.get("hints")
    if hints is not None:
        from .journeyman import HINT_COUNT

        if not 1 <= len(hints) <= HINT_COUNT:
            raise ValueError(f"{row.id}: expected 1-{HINT_COUNT} hints, got {len(hints)}")
        if [h["order"] for h in hints] != list(range(1, len(hints) + 1)):
            raise ValueError(f"{row.id}: hint orders must be 1..{len(hints)}")
        if len({h["dimension"] for h in hints}) != len(hints):
            raise ValueError(f"{row.id}: two hints from the same dimension")
        for h in hints:
            if not h.get("text", "").strip() or not h.get("label", "").strip():
                raise ValueError(f"{row.id}: hint {h['order']} is missing text or a label")
            leaked = _leaked_name_part(answer["canonical"], h["text"])
            if leaked:
                raise ValueError(
                    f"{row.id}: hint {h['order']} leaks {leaked!r} from the answer: {h['text']!r}")


# The generator's own rule, imported rather than restated. These two MUST agree: `validate`
# rejecting a leak the clue builder is willing to emit doesn't protect anyone, it just kills
# the run on a row that was already written (see `whoami_clues.leaked_name_part`).
_leaked_name_part = leaked_name_part


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
    for cl in clues:
        leaked = _leaked_name_part(answer["canonical"], cl["text"])
        if leaked:
            raise ValueError(f"{row.id}: clue {cl['order']} leaks {leaked!r} "
                             f"from the answer: {cl['text']!r}")
