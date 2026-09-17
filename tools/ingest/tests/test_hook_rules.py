"""Every board the generator can build must make sense on its face (themes.hook_problems).

Written after the NFL 2026 Week 1 pack's "Five-and-a-half-a-carry games" deep cut kept Nico
Collins for ONE 7-yard carry, on cards that showed neither carries nor yards per carry. The fix
for that one quirk was not the fix: the same two holes (a rate with no volume under it, a hook
the card never shows) were open on ~5,000 other generated themes across six sports. These tests
walk the whole generated space, so a new quirk that reopens either one fails here, on push,
before any mint can build it.
"""
from __future__ import annotations

import pytest

from tools.ingest import curation, generate
from tools.ingest.models import RawSeason
from tools.ingest.themes import (KEEP4_THEMES, Filter, StatColumn, Theme, card_hides_hook, format_columns,
                                 hook_problems)


def _generated():
    for name, cfg in curation.SPORTS.items():
        for theme in generate._candidates(cfg) + generate._pairwise_candidates(cfg):
            yield name, theme


def test_every_generated_theme_passes_the_hook_rules():
    bad = [(name, t.key, p) for name, t in _generated() for p in hook_problems(t)]
    assert not bad, f"{len(bad)} themes break a hook rule, e.g. {bad[:5]}"


def test_every_position_card_shows_its_hooks():
    """The theme can list the hook and a card can still drop it: a cross-position board renders
    each card from that position's canonical line, and on 2026 Week 1's deep cut the RBs' cards
    showed neither carries nor yards per carry while the QBs' did."""
    bad = []
    for _, theme in _generated():
        for position in sorted(theme.positions):
            hidden = card_hides_hook(theme, position)
            if hidden:
                bad.append((theme.key, position, hidden))
    assert not bad, f"{len(bad)} cards hide a hook, e.g. {bad[:5]}"


def test_every_curated_theme_passes_the_hook_rules():
    bad = [(t.key, p) for t in KEEP4_THEMES for p in hook_problems(t)]
    assert not bad, bad


def _theme(filters, columns, grain="game", min_stats=None):
    return Theme(key="t", title="t", sport="nfl", scale="nfl_fantasy_game", positions=frozenset({"RB"}),
                 min_stats=min_stats or {}, columns=columns, filters=tuple(filters), grain=grain)


YPC = StatColumn("ypc", "Yds/Carry", "dec1")


def test_the_week_1_deep_cut_as_it_shipped_is_rejected():
    shipped = _theme([Filter("ypc", "gte", 5.5)], [StatColumn("rushing_yards", "Rush Yds", "comma_int")])
    problems = hook_problems(shipped)
    assert any("ypc needs a volume floor" in p for p in problems)
    assert any("filters on ypc but the card never shows it" in p for p in problems)


def test_a_floor_below_the_minimum_is_not_a_floor():
    assert hook_problems(_theme([Filter("ypc", "gte", 5.5), Filter("carries", "gte", 1)], [YPC]))
    assert not hook_problems(_theme([Filter("ypc", "gte", 5.5), Filter("carries", "gte", 5)], [YPC]))


def test_a_position_minimum_counts_as_the_floor():
    assert not hook_problems(_theme([Filter("ypc", "gte", 5.5)], [YPC], min_stats={"carries": 12}))


def test_bio_fields_and_rate_backers_need_not_be_on_the_card():
    theme = _theme([Filter("draft_round", "eq", 1), Filter("ypc", "gte", 5.5), Filter("carries", "gte", 5)], [YPC])
    assert not hook_problems(theme)


def test_building_a_single_quirk_theme_that_breaks_a_rule_stops_the_mint():
    spec = curation.SPORTS["nfl-games"].positions["RB"]
    bad = curation.Quirk("fluke", (Filter("ypc", "gte", 5.5),), "Fluke games")
    with pytest.raises(ValueError, match="volume floor"):
        generate._theme("gen-bad", "Fluke games", spec, bad.filters, sport="nfl", quirks=(bad,))


def test_promoted_hook_columns_render_derived_stats():
    """ISO is computed from the line, not stored; its column must not print 0.000."""
    iso = generate._known_columns("baseball")["iso"]
    theme = Theme(key="t", title="t", sport="baseball", scale="x", positions=frozenset({"H"}),
                  min_stats={}, columns=[iso])
    assert format_columns(theme, {"slg": 0.600, "avg": 0.300}) == [{"label": "ISO", "value": "0.300"}]
