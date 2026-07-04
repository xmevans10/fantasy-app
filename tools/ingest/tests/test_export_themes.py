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
    }
    for t in KEEP4_THEMES:
        if t.grain == "season":
            assert t.scale in app_presets, f"{t.key} uses non-app scale {t.scale}"


def test_cross_position_column_slicing():
    """Per-position columns for the cross-position theme (mirrored by Keep4ThemeTests):
    a WR card on nfl-total-fantasy carries only receiving(+rushing) columns, a QB card
    passing+rushing; single-position themes are untouched."""
    from tools.ingest.themes import columns_for

    total = next(t for t in KEEP4_THEMES if t.key == "nfl-total-fantasy")
    assert [c.stat for c in columns_for(total, "WR")] == [
        "receptions", "receiving_yards", "receiving_tds"]
    assert [c.stat for c in columns_for(total, "QB")] == [
        "passing_yards", "passing_tds", "rushing_yards", "rushing_tds"]
    assert [c.stat for c in columns_for(total, "RB")] == [
        "rushing_yards", "rushing_tds", "receptions", "receiving_yards", "receiving_tds"]

    wr = next(t for t in KEEP4_THEMES if t.key == "nfl-wr-receiving")
    assert columns_for(wr, "WR") == wr.columns          # single-position: unchanged
    nba = next(t for t in KEEP4_THEMES if t.key == "nba-scorers")
    assert columns_for(nba, "G") == nba.columns         # NBA: unchanged
