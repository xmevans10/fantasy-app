"""Parity tests for the knowledge model's Python mirror.

`ladder.py` re-implements `BallIQ/Models/BotKnowledge.swift` so the ladder can solve each rung's
`bot_skill` against the bot's *real* policy — the same duplicate-and-pin arrangement
`grade.py`/`GradeFormula.swift` live under. The full pin is `BallIQTests/LadderCurveTests`, which
replays every rung with the real Swift solver, but that needs a dumped fixture and skips without
one. These run on a fresh checkout with no database and catch the drift that is both most likely
and cheapest to catch: a constant edited on one side only.
"""
import pathlib
import re

from tools.ingest.ladder import (KNOWLEDGE_MAX_DELTA, TIER_FAME, decision_contexts,
                                 hit_probability, knowledge_delta, whoami_era_midpoint)

SWIFT = (pathlib.Path(__file__).resolve().parents[3]
         / "BallIQ" / "Models" / "BotKnowledge.swift").read_text(encoding="utf-8")

# Hal the Archivist, as `BotKnowledgeTests` declares him — the two files assert the same numbers
# on the same profile on purpose, so a reviewer can diff them by eye.
ARCHIVIST = {"era_from": 1960, "era_to": 2010, "era_fade": 0.07,
             "sports": {"nba": -0.12, "nfl": -0.12, "baseball": -0.12},
             "other_sports": 0.12, "fame_bias": -0.12}


def test_max_delta_matches_the_swift_constant():
    found = re.search(r"static let maxDelta = ([0-9.]+)", SWIFT)
    assert found, "couldn't find BotKnowledge.maxDelta"
    assert float(found.group(1)) == KNOWLEDGE_MAX_DELTA


def test_tier_fame_table_matches_the_swift_one():
    body = re.search(r"static func fame\(for difficulty: SubjectDifficulty\?\).*?\n    \}",
                     SWIFT, re.S)
    assert body, "couldn't find DecisionContext.fame(for:)"
    found = re.findall(r"case \.(easy|medium|hard): return ([0-9.]+)", body.group(0))
    assert {k: float(v) for k, v in found} == TIER_FAME


def test_neutral_profile_is_the_identity():
    ctx = {"sport": "nba", "year": 1971, "fame": 0.9}
    assert knowledge_delta(None, ctx) == 0
    assert knowledge_delta({}, ctx) == 0
    assert knowledge_delta(ARCHIVIST, None) == 0
    for d in (0.0, 0.25, 0.5, 1.0):
        assert hit_probability(0.7, d, "consistent", 0.0, None, ctx) == hit_probability(0.7, d)


def test_era_term_matches_the_swift_cases():
    """The same four cases `testInsideTheEraIsSharperAndOutsideDecaysPerDecade` asserts."""
    era = {"era_from": 1960, "era_to": 2010, "era_fade": 0.07}
    assert knowledge_delta(era, {"year": 1985}) == -0.035       # home: half the fade, as a bonus
    assert abs(knowledge_delta(era, {"year": 2020}) - 0.07) < 1e-9    # one decade out
    assert abs(knowledge_delta(era, {"year": 2030}) - 0.14) < 1e-9    # two
    assert abs(knowledge_delta(era, {"year": 1950}) - 0.07) < 1e-9    # symmetric


def test_open_ended_era_only_fades_on_the_side_it_bounds():
    solomon = {"era_to": 1990, "era_fade": 0.1}
    assert knowledge_delta(solomon, {"year": 1908}) == -0.05
    assert abs(knowledge_delta(solomon, {"year": 2020}) - 0.30) < 1e-9


def test_unlisted_sport_falls_back_to_other_sports():
    assert abs(knowledge_delta(ARCHIVIST, {"sport": "nba"}) - -0.12) < 1e-9
    assert abs(knowledge_delta(ARCHIVIST, {"sport": "f1"}) - 0.12) < 1e-9
    assert knowledge_delta(ARCHIVIST, {"sport": None}) == 0


def test_fame_term_signs_point_the_right_way():
    # Positive bias = better on household names, and easier means a LOWER difficulty.
    assert abs(knowledge_delta({"fame_bias": 0.2}, {"fame": 1.0}) - -0.2) < 1e-9
    assert abs(knowledge_delta({"fame_bias": 0.2}, {"fame": 0.0}) - 0.2) < 1e-9
    assert knowledge_delta({"fame_bias": 0.2}, {"fame": 0.5}) == 0
    assert knowledge_delta({"fame_bias": -0.3}, {"fame": None}) == 0


def test_total_swing_is_clamped_both_ways():
    absurd = {"era_from": 2000, "era_to": 2001, "era_fade": 0.4,
              "other_sports": 0.4, "fame_bias": -0.4}
    assert knowledge_delta(absurd, {"sport": "f1", "year": 1900, "fame": 0.0}) == KNOWLEDGE_MAX_DELTA
    best = {"era_from": 2000, "era_to": 2001, "era_fade": 0.4,
            "sports": {"nba": -0.4}, "fame_bias": 0.9}
    assert knowledge_delta(best, {"sport": "nba", "year": 2000, "fame": 1.0}) == -KNOWLEDGE_MAX_DELTA


def test_knowledge_is_applied_before_style():
    """Order is load-bearing: `deepCuts` has to invert a difficulty that already knows what the
    decision was about. The Swift side pins the same property in `testKnowledgeIsAppliedBeforeStyle`.
    """
    from tools.ingest.ladder import style_difficulty
    k = {"sports": {"nba": 0.3}}
    ctx = {"sport": "nba"}
    actual = hit_probability(0.7, 0.4, "deepCuts", 0.0, k, ctx)
    knowledge_first = 0.7 ** style_difficulty("deepCuts", 0.7, 0.0)
    style_first = 0.7 ** (style_difficulty("deepCuts", 0.4, 0.0) + 0.3)
    assert abs(actual - knowledge_first) < 1e-12
    assert abs(actual - style_first) > 1e-6


# ── Context extraction ────────────────────────────────────────────────────────

def test_keep4_contexts_carry_the_card_year_and_no_fame():
    content = {"players": [{"seasonYear": 1998}, {"seasonYear": 2015}]}
    got = decision_contexts("keep4", "nfl", content)
    assert got == [{"sport": "nfl", "year": 1998}, {"sport": "nfl", "year": 2015}]
    # No fame key at all, rather than a fabricated one: the catalog has production percentiles,
    # not recognition, and a fake would re-read the signal `difficulty` already read.
    assert all("fame" not in c for c in got)


def test_grid_contexts_are_sport_only():
    got = decision_contexts("grid", "nba", {"cells": [{}, {}, {}]})
    assert got == [{"sport": "nba"}] * 3


def test_whoami_contexts_carry_the_era_midpoint_and_the_tier():
    content = {"difficulty": "hard", "clues": [{"kind": "era", "text": "Played from 1992 to 2011"},
                                               {"kind": "position", "text": "WR"}]}
    got = decision_contexts("whoami", "soccer", content)
    assert got == [{"sport": "soccer", "year": 2001, "fame": 0.15}] * 2


def test_era_midpoint_is_the_middle_not_the_debut():
    assert whoami_era_midpoint({"clues": [{"kind": "era", "text": "Played from 1992 to 2011"}]}) == 2001
    assert whoami_era_midpoint({"clues": [{"kind": "era", "text": "Played in 1998"}]}) == 1998
    assert whoami_era_midpoint({"clues": [{"kind": "position", "text": "QB"}]}) is None
    assert whoami_era_midpoint({"clues": []}) is None


def test_an_unrated_subject_keeps_a_none_fame_rather_than_becoming_medium():
    got = decision_contexts("whoami", "nfl", {"clues": [{}], "difficulty": None})
    assert got[0]["fame"] is None


# ── Home sport ────────────────────────────────────────────────────────────────

def test_home_sports_needs_a_real_specialism_not_just_a_listing():
    from tools.ingest.ladder import home_sports
    assert home_sports({"sports": {"soccer": -0.12}, "other_sports": 0.23}) == {"soccer"}
    # Ties are all home — Hal's tape covers three sports equally.
    assert home_sports({"sports": {"nba": -0.12, "nfl": -0.12, "baseball": -0.12},
                        "other_sports": 0.12}) == {"nba", "nfl", "baseball"}
    # Listed but no better than the fallback: not a specialism, so the ladder picks as before.
    assert home_sports({"sports": {"nba": 0.1}, "other_sports": 0.0}) == set()
    assert home_sports({"sports": {"nba": 0.2}, "other_sports": 0.2}) == set()
    assert home_sports(None) == set()
    assert home_sports({}) == set()


def test_every_roster_profile_with_a_specialism_names_a_real_sport():
    """A home sport that no board can ever have is a preference that silently never fires."""
    import json
    import pathlib
    from tools.ingest.ladder import SPORTS, home_sports
    roster = json.loads((pathlib.Path(__file__).resolve().parents[3]
                         / "tools" / "roster" / "roster.json").read_text())["bots"]
    for bot in roster:
        assert home_sports(bot.get("knowledge")) <= set(SPORTS), bot["id"]


def test_sport_term_is_the_sport_half_of_the_delta():
    from tools.ingest.ladder import sport_term
    prof = {"sports": {"soccer": -0.12}, "other_sports": 0.23}
    assert sport_term(prof, "soccer") == -0.12
    assert sport_term(prof, "nba") == 0.23          # unlisted -> the fallback
    assert sport_term(prof, None) == 0.0
    # A neutral profile treats every sport alike, which is what collapses `poolable` back to
    # the difficulty-only count it was before knowledge existed.
    assert sport_term(None, "nba") == sport_term(None, "soccer") == 0.0
    assert sport_term({}, "nba") == sport_term({}, "f1") == 0.0
