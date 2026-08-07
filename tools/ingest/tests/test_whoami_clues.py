"""Tests for the Who Am I? clue dimension library (pure — no network, no Supabase).

The behaviour worth pinning here is the stuff that isn't obvious from reading one builder:
the wire-compatibility contract on `kind`, the vague→specific ordering that survives a
random draw, the redundancy rules, and the per-tier bias. The individual text builders are
covered indirectly (every dimension is exercised by `test_every_dimension_can_fire`).
"""
import random

import pytest

from tools.ingest import whoami_clues
from tools.ingest.models import WhoAmIEntry
from tools.ingest.whoami_clues import (CLUE_COUNT, DIMENSIONS, POINT_MULTIPLIER,
                                       available_clues, difficulty_of, select_clues)
from tools.ingest.validate import _VALID_KINDS

# A subject with every dimension populated, so a draw has the full space to choose from.
RICH = WhoAmIEntry(
    sport="nfl", canonical="Test Player", aliases=["test player"], position="Wide receiver",
    first_year=2004, last_year=2016, teams=["Falcons", "Packers", "Jets"],
    stat_line="9,000 receiving yards and 60 touchdown catches", jersey="84",
    fact="Caught a famous game-winner", college="Southern Mississippi",
    college_conference="Sun Belt Conference", height_in=74, weight_lb=210, birth_year=1982,
    draft_year=2004, draft_round=2, draft_pick=33, draft_team="Ravens", seasons=13,
    best_season={"year": 2010, "team": "Packers", "line": "1,400 yards and 12 scores"},
    nickname="The Test", accolades=["Three Pro Bowls"], fame=0.7,
)

# The opposite: only the fields `WhoAmIEntry` requires, all of them empty where allowed.
# Mirrors a thin hand-authored entry, which must still produce a usable puzzle.
THIN = WhoAmIEntry(
    sport="nba", canonical="Thin Subject", aliases=[], position="Guard",
    first_year=1999, last_year=2005, teams=["Bulls"], stat_line="12.0 points per game",
    jersey="", fact="",
)


def _entry(**kwargs) -> WhoAmIEntry:
    from dataclasses import replace
    return replace(RICH, **kwargs)


# ── The wire-compatibility contract ───────────────────────────────────────────

def test_every_dimension_maps_onto_a_legacy_clue_kind():
    """The load-bearing invariant of this module: a `kind` the shipped App Store build can't
    decode fails the whole whoami fetch for those users. See whoami_clues' module docstring."""
    for dimension in DIMENSIONS:
        assert dimension.kind in _VALID_KINDS, (
            f"{dimension.key} uses kind {dimension.kind!r}, which older clients cannot decode")


def test_every_dimension_has_a_distinct_key_and_a_label():
    keys = [d.key for d in DIMENSIONS]
    assert len(keys) == len(set(keys))
    assert all(d.label and d.family and 0.0 <= d.reveal <= 1.0 for d in DIMENSIONS)


def test_point_multipliers_match_the_swift_table():
    """`WhoAmIPuzzle.Difficulty.multiplier` is the client's own copy of POINT_MULTIPLIER (the
    client deliberately doesn't trust a number from content). Read it back out of the Swift
    source so the two can't drift silently — the same posture as the grade-formula ports."""
    import pathlib
    import re
    swift = (pathlib.Path(__file__).resolve().parents[3]
             / "BallIQ" / "Models" / "WhoAmIPuzzle.swift").read_text(encoding="utf-8")
    # Scoped to the `multiplier` body — `Difficulty` has several other easy/medium/hard
    # switches (symbol, tint, tintBg …) and a looser pattern picks those up too.
    body = re.search(r"var multiplier: Double \{(.*?)\n        \}", swift, re.S)
    assert body, "couldn't find Difficulty.multiplier's switch in WhoAmIPuzzle.swift"
    found = dict(re.findall(r"case \.(easy|medium|hard): return ([0-9.]+)", body.group(1)))
    assert {k: float(v) for k, v in found.items()} == POINT_MULTIPLIER


# ── Selection ─────────────────────────────────────────────────────────────────

def test_every_dimension_can_fire():
    """Every registered dimension produces a clue for a fully-populated subject, so a dead
    builder (a typo'd field name, say) can't sit in the registry unnoticed."""
    rng = random.Random(0)
    tennis = _entry(sport="tennis", nationality="France", teams=[], league="")
    soccer = _entry(sport="soccer", league="England", undrafted=True, active=True)
    one_club = _entry(teams=["Packers"], franchise_count=1, draft_team="")
    fired = set()
    for entry in (RICH, tennis, soccer, one_club, _entry(undrafted=True, draft_year=None)):
        fired |= {c.dimension for c in available_clues(entry, rng)}
    registered = {d.key for d in DIMENSIONS}
    assert fired == registered, f"never fired: {sorted(registered - fired)}"


def test_selection_returns_six_distinct_dimensions():
    clues = select_clues(RICH, seed="2026-08-06")
    assert len(clues) == CLUE_COUNT
    assert len({c.dimension for c in clues}) == CLUE_COUNT
    assert len({c.text for c in clues}) == CLUE_COUNT


def test_clues_are_ordered_vague_to_specific():
    """Ordering is jittered, so this asserts the *trend* rather than a strict sort: the
    opening clue must not be more revealing than the closer."""
    clues = select_clues(RICH, seed="2026-08-06")
    assert clues[0].reveal < clues[-1].reveal


def test_same_seed_is_reproducible_and_different_seeds_differ():
    a = [c.dimension for c in select_clues(RICH, seed="2026-08-06")]
    b = [c.dimension for c in select_clues(RICH, seed="2026-08-06")]
    assert a == b
    others = {tuple(c.dimension for c in select_clues(RICH, seed=f"2026-09-{d:02d}"))
              for d in range(1, 15)}
    assert len(others) > 1, "the draw never varies across seeds"


def test_a_thin_subject_still_gets_a_full_card_without_repeating_itself():
    clues = select_clues(THIN, seed="x")
    assert len({c.dimension for c in clues}) == len(clues)
    assert len(clues) >= 4      # era/longevity/position/teams/statLine/initials are available


def test_redundant_dimensions_never_appear_together():
    for seed in (f"seed-{i}" for i in range(60)):
        picked = {c.dimension for c in select_clues(RICH, seed=seed)}
        for group in whoami_clues._REDUNDANT:
            assert len(picked & group) <= 1, f"{picked & group} drawn together on {seed}"


def test_one_angle_cannot_fill_the_whole_card():
    """Family spread — six production stats in a row would be a worse puzzle than six
    different angles, regardless of how revealing each one is."""
    for seed in (f"seed-{i}" for i in range(40)):
        families = [c.family for c in select_clues(RICH, seed=seed)]
        assert max(families.count(f) for f in set(families)) <= 2


def test_hard_puzzles_draw_vaguer_clues_than_easy_ones():
    """The tier's second lever (the first is how obscure the subject is): an easy card leans
    on identifying dimensions, a hard one has to be worked out from broader ones."""
    def mean_reveal(difficulty: str) -> float:
        totals = [sum(c.reveal for c in select_clues(RICH, seed=f"s{i}", difficulty=difficulty))
                  for i in range(40)]
        return sum(totals) / len(totals)

    assert mean_reveal("easy") > mean_reveal("medium") > mean_reveal("hard")


# ── Difficulty ────────────────────────────────────────────────────────────────

def test_tier_derives_from_fame_and_an_explicit_override_wins():
    assert difficulty_of(_entry(fame=0.99, difficulty="")) == "easy"
    assert difficulty_of(_entry(fame=0.70, difficulty="")) == "medium"
    assert difficulty_of(_entry(fame=0.20, difficulty="")) == "hard"
    assert difficulty_of(_entry(fame=0.20, difficulty="easy")) == "easy"


def test_an_unscored_curated_entry_is_easy():
    """A hand-authored legend has no fame percentile — the curated pool *is* the famous pool,
    so absent fame means easy rather than defaulting to the hard end."""
    assert difficulty_of(_entry(fame=None, difficulty="")) == "easy"


# ── Individual builders worth pinning ─────────────────────────────────────────

def test_active_players_are_never_described_as_retired():
    """An active player's clues must not assert a final season — wrong, and it misdates the
    career. Checked across many draws since the relevant dimensions are randomly selected."""
    active = _entry(active=True, last_year=2026)
    for seed in (f"a{i}" for i in range(60)):
        for clue in select_clues(active, seed=seed):
            assert "final season" not in clue.text.lower()
            assert "last suited up" not in clue.text.lower()
            assert "finished up with" not in clue.text.lower()


def test_undrafted_is_only_claimed_when_it_is_actually_known():
    rng = random.Random(1)
    unknown = {c.dimension for c in available_clues(_entry(undrafted=False, draft_year=None), rng)}
    assert "undrafted" not in unknown
    known = {c.dimension for c in available_clues(_entry(undrafted=True, draft_year=None), rng)}
    assert "undrafted" in known


def test_franchise_count_stays_true_when_some_teams_cannot_be_named():
    """`teams` holds only the franchises that could be named; the count clue must report the
    real total, and the naming clues must stay silent rather than imply a shorter career."""
    rng = random.Random(2)
    partial = _entry(teams=["Falcons", "Packers"], franchise_count=5, teams_named=False)
    clues = {c.dimension: c.text for c in available_clues(partial, rng)}
    assert "5 different franchises" in clues["franchiseCount"] or "5 teams" in clues["franchiseCount"]
    assert "teams" not in clues and "firstTeam" not in clues and "lastTeam" not in clues


def test_soccer_clubs_take_no_definite_article():
    rng = random.Random(3)
    soccer = _entry(sport="soccer", teams=["Ajax Amsterdam", "Arsenal"],
                    best_season={"year": 2010, "team": "Arsenal", "line": "20 goals"})
    texts = " ".join(c.text for c in available_clues(soccer, rng))
    assert "the Arsenal" not in texts and "the Ajax" not in texts


def test_ordinal_and_height_formatting():
    assert whoami_clues.ordinal(1) == "1st"
    assert whoami_clues.ordinal(2) == "2nd"
    assert whoami_clues.ordinal(3) == "3rd"
    assert whoami_clues.ordinal(11) == "11th"
    assert whoami_clues.ordinal(22) == "22nd"
    assert whoami_clues.height_text(74) == "6'2\""
    assert whoami_clues.height_text(72) == "6'0\""
    assert whoami_clues.height_text(0) == ""      # bad bio row, not a 0'0" player
    assert whoami_clues.height_text(300) == ""


def test_article_agreement_on_season_counts():
    assert whoami_clues.article_for("11") == "an"
    assert whoami_clues.article_for("18") == "an"
    assert whoami_clues.article_for("8") == "an"
    assert whoami_clues.article_for("13") == "a"
    assert whoami_clues.article_for("20") == "a"


def test_answer_leak_guard_matches_whole_words_only():
    """Caught on the live pool: "Competed for USA" (Pete Sampras's nationality clue) tripped
    the guard because "com-PETE-d" contains his first name. A substring test makes the check
    unusable; it has to be word-boundary matched."""
    from tools.ingest.assemble import PuzzleRow
    from tools.ingest.validate import _validate_whoami

    def row(answer: str, leaky_text: str) -> PuzzleRow:
        clues = [{"order": i, "kind": "fact", "text": f"Filler clue {i}",
                  "dimension": f"d{i}", "label": "X"} for i in range(1, 6)]
        clues.append({"order": 6, "kind": "teams", "text": leaky_text,
                      "dimension": "nationality", "label": "Country"})
        return PuzzleRow(id="t", sport="tennis", format="whoami",
                         content={"clues": clues, "difficulty": "easy",
                                  "answer": {"canonical": answer, "aliases": []}})

    _validate_whoami(row("Pete Sampras", "Competed for USA"))       # must not raise
    with pytest.raises(ValueError, match="leaks"):
        _validate_whoami(row("Pete Sampras", "Beat Pete in the final"))
    with pytest.raises(ValueError, match="leaks"):
        _validate_whoami(row("Pete Sampras", "Sampras won here"))


def test_join_list():
    assert whoami_clues.join_list(["A"]) == "A"
    assert whoami_clues.join_list(["A", "B"]) == "A and B"
    assert whoami_clues.join_list(["A", "B", "C"]) == "A, B and C"
    assert whoami_clues.join_list([]) == ""
