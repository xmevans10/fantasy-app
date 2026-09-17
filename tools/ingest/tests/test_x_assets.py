"""X post assets: captions X will accept, colors that match the app, renders that don't fail.

Lives with the ingest tests because the minting workflows are what run it. Caption and parity
tests need no Pillow (the ingest runtime is stdlib-only); rendering tests skip without it.
"""
from __future__ import annotations

import json
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


# ── spec (the Swift renderer's input) ──────────────────────────────────────────

def _k4(sport="nfl"):
    return {"id": f"k-{sport}", "sport": sport, "content": {"id": f"k-{sport}", "sport": sport,
            "theme": "Test board", "players": [
                {"id": f"p{i}", "name": f"Player {i}", "teamAbbr": "KC", "grade": 30.0 - i}
                for i in range(8)]}}


def test_daily_posts_cover_every_published_format(monkeypatch, tmp_path):
    """The old renderer only ever made K4C4 posts, though Journeyman and Who Am I? publish a
    daily per sport too."""
    journey = {"id": "j", "sport": "nfl", "content": {"stints": [{"teamName": "Bears"}, {"teamName": "Lions"}],
                                                      "answer": {"canonical": "X Y"}}}
    whoami = {"id": "w", "sport": "nfl", "content": {"clues": [{"text": "Drafted in 2010"}] * 6}}
    monkeypatch.setattr(x_assets, "daily_boards", lambda d: [_k4("nfl"), _k4("nba")])
    monkeypatch.setattr(x_assets, "dated", lambda d, f: {"nfl": journey if f == "journeyman" else whoami})
    monkeypatch.setattr(x_assets, "teams_rows", lambda sports: [])
    assets = x_assets.build(tmp_path, daily="2026-09-17", answers="2026-09-16", packs=None,
                            sport=None, draw=False)
    kinds = sorted({a["kind"] for a in assets})
    assert kinds == ["answers", "daily", "journeyman", "journeyman-answer", "lineup", "whoami"]
    assert all(x_assets.x_length(a["caption"]) <= x_assets.X_LIMIT for a in assets)
    # The manifest never carries board content; the spec carries everything the renderer needs.
    assert not any("content" in a for a in assets)
    spec = json.loads((tmp_path / "spec.json").read_text())
    assert {p["kind"] for p in spec["posts"]} == set(kinds)
    assert all("content" in p for p in spec["posts"] if p["kind"] in ("daily", "whoami", "journeyman"))
    # Hidden-answer posts never name the player anywhere a reader would see before playing.
    for a in assets:
        if a["kind"] == "journeyman":
            assert "X Y" not in a["caption"] + a["alt"]


def test_a_fresh_drop_cron_names_exactly_its_own_sports():
    """Both Tuesday crons fire five minutes apart; each must post only its own pack."""
    assert x_assets.cron_sports("30 8 * * 2") == ["nfl"]
    assert x_assets.cron_sports("35 8 * * 2") == ["soccer"]
    assert sorted(x_assets.cron_sports("30 8 * * 3")) == ["baseball", "hockey", "nba"]
    assert x_assets.cron_sports("0 0 * * *") == []


def test_lineup_caption_only_promises_boards_that_exist():
    """Tennis has no Journeyman; its lineup must not advertise one."""
    tennis = x_assets.caption_lineup("tennis", "Multi-slam tour seasons", whoami=True, journeyman=False)
    assert "mystery player" in tennis and "career" not in tennis
    assert x_assets.x_length(tennis) <= x_assets.X_LIMIT


def test_one_morning_mixes_layouts():
    layouts = {x_assets.daily_layout("2026-09-17", s) for s in ("nfl", "nba", "baseball")}
    assert len(layouts) == 3
    assert x_assets.daily_layout("2026-09-17", "nfl") != x_assets.daily_layout("2026-09-18", "nfl")


def test_every_post_kind_files_into_a_day_or_pack_folder():
    from tools.marketing import drive
    for kind in ("daily", "lineup", "journeyman", "whoami", "answers", "journeyman-answer"):
        folder, _ = drive.place({"kind": kind, "sport": "nfl", "date": "2026-09-16"})
        assert folder[0] == "Daily posts", kind


def test_fit_respects_width_for_a_single_long_word():
    pytest.importorskip("PIL")
    from PIL import Image, ImageDraw
    d = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    f, lines = brand.fit(d, "JOURNEYMAN", brand.anton, 640, 2, 150, 60)
    assert all(brand.text_w(d, ln, f) <= 640 for ln in lines)
