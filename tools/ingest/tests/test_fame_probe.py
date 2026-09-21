"""Tests for the fame probe's pure parts (no network, no model, no key).

The probe's whole value is the diff it prints, so the mapping and sampling have to be right
before anyone reads a number off it — a share mapping that quietly changed the tier mix, or
a sampler that over-drew one bucket, would manufacture exactly the disagreement the probe
claims to have found.
"""
import collections

from tools.ingest.fame_probe import (offline_answers, sample, share_matched_tiers, spearman,
                                     subject_state, tier_from_score)
from tools.ingest.models import WhoAmIEntry
from tools.ingest.whoami_clues import difficulty_of


def _entry(canonical: str, sport: str = "nfl", fame: float = 0.5) -> WhoAmIEntry:
    return WhoAmIEntry(sport=sport, canonical=canonical, aliases=[], position="WR",
                       first_year=2000, last_year=2010, teams=["SF"],
                       stat_line="1,000 yards", jersey="80", fact="", seasons=10, fame=fame)


def test_tier_from_score_cuts_the_recognition_ladder():
    assert tier_from_score(3.0) == "easy"
    assert tier_from_score(2.0) == "easy"
    assert tier_from_score(1.99) == "medium"
    assert tier_from_score(1.0) == "medium"
    assert tier_from_score(0.99) == "hard"


def test_share_mapping_preserves_the_tier_mix_per_sport():
    scored = [{"key": f"nfl:{i}", "sport": "nfl", "p_casual": i / 10,
               "current_tier": t}
              for i, t in enumerate(["easy", "easy", "medium", "medium", "medium", "hard"])]
    proposed = share_matched_tiers(scored)
    assert collections.Counter(proposed.values()) == collections.Counter(
        r["current_tier"] for r in scored)


def test_share_mapping_orders_by_probability_not_by_current_tier():
    # The most-recognized subject currently ships as `hard`; the share mapping must move it
    # to `easy` and push somebody else down, which is the reordering the probe exists to see.
    scored = [{"key": "nfl:famous", "sport": "nfl", "p_casual": 0.99, "current_tier": "hard"},
              {"key": "nfl:mid", "sport": "nfl", "p_casual": 0.50, "current_tier": "medium"},
              {"key": "nfl:obscure", "sport": "nfl", "p_casual": 0.01, "current_tier": "easy"}]
    proposed = share_matched_tiers(scored)
    assert proposed["nfl:famous"] == "easy"
    assert proposed["nfl:mid"] == "medium"
    assert proposed["nfl:obscure"] == "hard"


def test_share_mapping_cuts_each_sport_against_its_own_shares():
    # F1's easy tier is a fraction of NFL's. Cutting globally would read that sampling
    # difference as a disagreement about individual drivers.
    scored = ([{"key": f"nfl:{i}", "sport": "nfl", "p_casual": 0.9 - i / 100,
                "current_tier": "easy" if i < 2 else "hard"} for i in range(4)]
              + [{"key": f"f1:{i}", "sport": "f1", "p_casual": 0.5 - i / 100,
                  "current_tier": "hard"} for i in range(4)])
    proposed = share_matched_tiers(scored)
    assert sum(1 for k, v in proposed.items() if k.startswith("nfl") and v == "easy") == 2
    assert all(v == "hard" for k, v in proposed.items() if k.startswith("f1"))


def test_spearman_is_rank_based_not_value_based():
    assert spearman([1.0, 2.0, 3.0], [10.0, 200.0, 3000.0]) == 1.0
    assert spearman([1.0, 2.0, 3.0], [3.0, 2.0, 1.0]) == -1.0
    assert spearman([1.0, 1.0], [1.0, 1.0]) == 0.0  # no variance -> no correlation


def test_sample_is_balanced_across_sport_and_tier_buckets():
    pool = ([_entry(f"Famous {i}", fame=0.99) for i in range(5)]
            + [_entry(f"Deep {i}", fame=0.01) for i in range(5)]
            + [_entry(f"NBA Famous {i}", sport="nba", fame=0.99) for i in range(5)])
    picked = sample(pool, per_tier=2, sports=None, seed=1)
    buckets = collections.Counter((e.sport, difficulty_of(e)) for e in picked)
    assert set(buckets.values()) == {2}
    assert len(buckets) == 3


def test_sample_is_deterministic_for_a_seed_and_filters_by_sport():
    pool = [_entry(f"P{i}", fame=0.99) for i in range(10)] + [_entry("NBA", sport="nba")]
    first = [e.canonical for e in sample(pool, per_tier=3, sports=["nfl"], seed=7)]
    again = [e.canonical for e in sample(pool, per_tier=3, sports=["nfl"], seed=7)]
    assert first == again
    assert "NBA" not in first


def test_state_carries_the_name_because_that_is_the_question():
    state = subject_state(_entry("Ottis Anderson"))
    assert state["name"] == "Ottis Anderson"
    assert state["career_span"] == "2000-2010"


def test_offline_answers_match_the_documented_api_shape():
    # The stub's only contract: every field `score_all` reads off a real response exists
    # here too, so the offline run proves the mapping code, not just the transport.
    answers = offline_answers(subject_state(_entry("Anyone")))
    assert set(answers) == {"casual_can_name", "recognition", "was_productive"}
    assert 0.0 <= answers["casual_can_name"]["noul"] <= 1.0
    assert answers["recognition"]["score"] in (0.0, 1.0, 2.0, 3.0)
    assert set(answers["recognition"]["probabilities"]) == {"0", "1", "2", "3"}


def test_offline_answers_are_stable_for_a_name():
    assert offline_answers({"name": "Same Guy"}) == offline_answers({"name": "Same Guy"})
