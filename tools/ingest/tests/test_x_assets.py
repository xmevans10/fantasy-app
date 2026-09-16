"""X post assets: captions X will accept, colors that match the app, renders that don't fail.

Lives with the ingest tests because the minting workflows are what run it. Caption and parity
tests need no Pillow (the ingest runtime is stdlib-only); rendering tests skip without it.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

from tools.marketing import brand, x_assets

ROOT = Path(__file__).resolve().parents[3]


def test_every_sport_color_matches_the_app():
    """brand.SPORT_FILL is a mirror of Theme.swift, so a recolor in the app must fail here
    rather than ship posts in last season's colors."""
    theme = (ROOT / "BallIQ" / "DesignSystem" / "Theme.swift").read_text()
    swift = {m.group(1).lower(): "#" + m.group(2).upper()
             for m in re.finditer(r"static let sport(\w+?)Fill\s*=\s*Color\(hex: 0x([0-9A-Fa-f]{6})\)", theme)}
    names = {"nfl": "nfl", "nba": "nba", "baseball": "mlb", "soccer": "soccer", "tennis": "tennis",
             "hockey": "hockey", "f1": "f1"}
    for sport, (fill, _) in brand.SPORT_FILL.items():
        assert swift[names[sport]] == fill.upper(), f"{sport}: app {swift[names[sport]]}, brand {fill}"


def test_links_count_as_23_characters():
    assert x_assets.x_length("hi https://apps.apple.com/app/id6785275045?ct=x_daily") == 3 + 23


@pytest.mark.parametrize("caption", [
    x_assets.caption_daily("nfl", "2026 Week 1: top performances, AFC West"),
    x_assets.caption_answers("baseball", "Ace pitching seasons", ["A", "B", "C", "D"]),
    x_assets.caption_pack("nfl", "2026 Week 1", 5, "Top performances, AFC West"),
    x_assets.caption_game("CAR", "CHI"),
])
def test_captions_fit_and_follow_house_style(caption):
    assert x_assets.x_length(caption) <= x_assets.X_LIMIT
    assert "—" not in caption, "no em dashes in anything a player reads"
    assert "ct=x_" in caption, "every post link carries a campaign token"


def test_an_overlong_theme_is_shortened_until_x_accepts_it():
    theme = "Week 1: " + "an extremely long and very specific theme title " * 12
    caption = x_assets.caption_daily("nfl", theme)
    assert x_assets.x_length(caption) <= x_assets.X_LIMIT
    assert caption.endswith("ct=x_daily")


def test_board_titles_drop_the_pack_label_once():
    assert x_assets._board_title("2026 Week 1: top TE performances", "2026 Week 1") == "Top TE performances"
    assert x_assets._board_title("CAR vs CHI, Sep 13, 2026: who had the better day?", "2026 Week 1") \
        == "CAR vs CHI, Sep 13, 2026: who had the better day?"


def test_accent_is_picked_by_measured_contrast():
    """Lime on NBA orange measured 2.35:1; the picker must choose something readable."""
    for sport, (fill, _) in brand.SPORT_FILL.items():
        assert brand.contrast(brand.accent_on(fill), fill) >= 3.0, sport


# ── rendering (needs Pillow) ────────────────────────────────────────────────────

def _board(n=8):
    return {"id": "t", "sport": "nfl", "content": {"theme": "Test board", "players": [
        {"id": f"p{i}", "name": f"Player Number {i}", "teamAbbr": "KC", "grade": 30.0 - i}
        for i in range(n)]}}


def test_renders_are_x_sized_without_network(monkeypatch):
    pytest.importorskip("PIL")
    monkeypatch.setattr(x_assets, "team", lambda sport, abbr: {})
    for render in (x_assets.render_daily, x_assets.render_answers):
        img = render(_board())
        assert img.size == (1600, 900)


def test_fit_respects_width_for_a_single_long_word():
    pytest.importorskip("PIL")
    from PIL import Image, ImageDraw
    d = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    f, lines = brand.fit(d, "JOURNEYMAN", brand.anton, 640, 2, 150, 60)
    assert all(brand.text_w(d, ln, f) <= 640 for ln in lines)
