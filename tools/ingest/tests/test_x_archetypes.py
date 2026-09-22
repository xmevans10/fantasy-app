"""The reply archetype portfolio and its safety gating."""
from __future__ import annotations

from tools.marketing import x_archetypes


def test_safe_archetypes_are_available_and_risky_ones_are_not():
    ids = x_archetypes.allowed()
    assert "fact" in ids and "meme" in ids and "question" in ids
    assert "hate" not in ids and "mock" not in ids          # risky/medium off by default


def test_medium_and_risky_are_opt_in():
    assert "mock" in x_archetypes.allowed(include_medium=True)
    assert "hate" in x_archetypes.allowed(include_risky=True)
    assert "hate" not in x_archetypes.allowed(include_medium=True)


def test_every_archetype_is_well_formed():
    for aid, a in x_archetypes.ARCHETYPES.items():
        assert a.id == aid
        assert a.safety in ("safe", "medium", "risky")
        assert a.prompt
        assert a.examples, f"{aid} needs a few-shot example"


def test_pick_is_deterministic_and_in_pool():
    pool = ["a", "b", "c"]
    assert x_archetypes.pick("same post", pool) == x_archetypes.pick("same post", pool)
    assert x_archetypes.pick("anything", pool) in pool


def test_get_unknown_is_none():
    assert x_archetypes.get("nope") is None
