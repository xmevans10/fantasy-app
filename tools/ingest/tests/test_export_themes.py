"""Theme-export parity: the bundled keep4_themes.json must equal export_themes(KEEP4_THEMES).

This is the M10 anti-drift lock. The app's creation templates decode the bundled file;
if a theme changes in themes.py without regenerating the bundle
(`python -m tools.ingest.main --write-themes`), this test fails.
"""
from __future__ import annotations

import json
from pathlib import Path

from tools.ingest.themes import KEEP4_THEMES, export_theme, export_themes

BUNDLED = Path(__file__).resolve().parents[3] / "BallIQ" / "Data" / "keep4_themes.json"


def test_bundled_themes_match_catalog():
    assert BUNDLED.exists(), "run: python -m tools.ingest.main --write-themes"
    bundled = json.loads(BUNDLED.read_text(encoding="utf-8"))
    assert bundled == export_themes(), (
        "keep4_themes.json is stale — regenerate with --write-themes")


def test_export_shape_locked_value():
    """Locked-value: the exact export row for nfl-wr-receiving (mirrored by Keep4ThemeTests)."""
    theme = next(t for t in KEEP4_THEMES if t.key == "nfl-wr-receiving")
    assert export_theme(theme) == {
        "key": "nfl-wr-receiving",
        "title": "Elite WR receiving seasons",
        "sport": "nfl",
        "scale": "nfl_skill_ppr",
        "positions": ["WR"],
        "minStats": {"games": 10, "receiving_yards": 1000},
        "columns": [
            {"stat": "receiving_yards", "label": "Rec Yds", "fmt": "comma_int"},
            {"stat": "receptions", "label": "Rec", "fmt": "int"},
            {"stat": "receiving_tds", "label": "Rec TD", "fmt": "int"},
            {"stat": "ypr", "label": "Yds/Rec", "fmt": "dec1"},
            {"stat": "targets", "label": "Tgts", "fmt": "int"},
        ],
        "poolCap": 24,
        "grain": "season",
        "eraAdjusted": False,
    }


def test_every_season_theme_scale_is_app_preset():
    """Season-grain themes must use a scale the app's ScoringRule.presets mirrors, so a
    creation template grades identically to the daily pipeline. (Game-grain scales are
    pipeline-only; the create flow never offers game themes.)"""
    app_presets = {
        "nfl_wr", "nfl_rb", "nfl_qb", "nba_scorer", "nba_big", "nba_playmaker",
        "nfl_fantasy", "nfl_skill_ppr", "nfl_qb_fantasy", "nba_fantasy",
        "baseball_hitter_fantasy", "baseball_pitcher_fantasy",
        "soccer_attacker_fantasy", "soccer_defender_fantasy", "tennis_fantasy",
        "hockey_skater_fantasy", "hockey_goalie_fantasy", "f1_driver_fantasy",
    }
    for t in KEEP4_THEMES:
        if t.grain == "season":
            assert t.scale in app_presets, f"{t.key} uses non-app scale {t.scale}"


def test_cross_position_card_composition():
    """Per-position columns for a cross-position theme (mirrored by Keep4ThemeTests).

    A WR/TE card carries the canonical receiving line, a QB the canonical passing line —
    composed from `POSITION_CARD`, not sliced out of the theme's own columns, so it holds
    even when the theme never declared `receiving_yards`. Single-position themes, and
    positions that produce every column the theme names, are untouched.
    """
    from tools.ingest.themes import columns_for

    total = next(t for t in KEEP4_THEMES if t.key == "nfl-total-fantasy")
    assert [c.stat for c in columns_for(total, "WR")] == [
        "receiving_yards", "receptions", "receiving_tds"]
    assert [c.stat for c in columns_for(total, "TE")] == [
        "receiving_yards", "receptions", "receiving_tds"]
    # INT is a scored term of `nfl_fantasy` (-2/pick) that the theme's columns omit; the
    # canonical QB card puts it back, so the number can be reasoned about on the card.
    assert [c.stat for c in columns_for(total, "QB")] == [
        "passing_yards", "passing_tds", "interceptions", "rushing_yards", "rushing_tds"]
    assert [c.stat for c in columns_for(total, "RB")] == [
        "rushing_yards", "rushing_tds", "receiving_yards", "receiving_tds", "receptions"]

    wr = next(t for t in KEEP4_THEMES if t.key == "nfl-wr-receiving")
    assert columns_for(wr, "WR") == wr.columns          # single-position: unchanged
    nba = next(t for t in KEEP4_THEMES if t.key == "nba-scorers")
    assert columns_for(nba, "G") == nba.columns         # NBA: no position split, unchanged
    # C/L/R record the same things, so a skater theme keeps its own emphasis rather than
    # being rewritten to canonical G-A-P.
    snipers = next(t for t in KEEP4_THEMES if t.key == "hockey-modern-snipers")
    assert columns_for(snipers, "C") == snipers.columns


def test_keeper_card_drops_outfield_stats():
    """A keeper in a DF/GK theme gets the two keeper numbers, not "Goals 0 · Assists 0".

    Soccer's whole vocabulary is four keys, so this card is honestly two tiles wide — the
    point of `POSITION_CARD` is that it never pads with stats the position doesn't record.
    """
    from tools.ingest.themes import columns_for

    backs = next(t for t in KEEP4_THEMES if t.key == "soccer-defenders")
    assert [c.stat for c in columns_for(backs, "GK")] == ["clean_sheets", "appearances"]
    assert columns_for(backs, "DF") == backs.columns    # a DF does produce all four


def test_no_theme_can_show_a_stat_its_position_never_records():
    """The guarantee, over every theme the pipeline can mint — curated AND generated.

    Not a spot check: `gen-any-all-towering` shipped Travis Kelce as "Pass Yds 0 · Pass TD 0
    · Rush TD 0 · Rec 110" on the 2026-09-06 daily, and every curated theme passed at the
    time. Generated themes cap columns at five (`generate._MAX_COLUMNS`), which is what
    truncated the receiving stats off the seven-stat NFL "ANY" spec, so the shapes that break
    this only exist after generation.
    """
    from tools.ingest import curation, generate
    from tools.ingest.themes import columns_for, produces

    candidates = list(KEEP4_THEMES)
    for cfg in curation.SPORTS.values():
        candidates += generate._candidates(cfg)

    offenders = [
        (t.key, pos, col.label)
        for t in candidates if len(t.positions) > 1
        for pos in sorted(t.positions)
        for col in columns_for(t, pos)
        if not produces(t.sport, pos, col.stat)
    ]
    assert not offenders, f"{len(offenders)} card columns a position never records: {offenders[:8]}"


def test_every_canonical_card_key_can_be_rendered():
    """`columns_for` can only fill a canonical key it has a label/format for — a key present
    in POSITION_CARD but missing from `_FILL_COLUMNS` would silently shorten the card."""
    from tools.ingest.themes import POSITION_CARD, POSITION_CARD_GAME, _FILL_COLUMNS

    for table in (POSITION_CARD, POSITION_CARD_GAME):
        for sport, by_position in table.items():
            for position, keys in by_position.items():
                missing = [k for k in keys if k not in _FILL_COLUMNS.get(sport, {})]
                assert not missing, f"{sport}/{position} canonical keys unrenderable: {missing}"


def test_canonical_card_keys_are_produced_by_their_position():
    """The two tables must agree: a canonical card may not name a stat the same position's
    family list says it never records."""
    from tools.ingest.themes import POSITION_CARD, POSITION_STAT_FAMILIES, produces

    for sport, by_position in POSITION_CARD.items():
        assert sport in POSITION_STAT_FAMILIES, f"{sport} has a card but no family table"
        for position, keys in by_position.items():
            wrong = [k for k in keys if not produces(sport, position, k)]
            assert not wrong, f"{sport}/{position} card names unproduced stats: {wrong}"
