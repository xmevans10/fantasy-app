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


def _p(pid, name, grade, sport="nfl", **kw):
    return {"id": f"{sport}-{pid}", "name": name, "grade": grade, "teamAbbr": "KC", "seasonYear": 2002,
            "stats": [{"label": "Rush Yds", "value": "1,615"}], **kw}


def _board(players, sport="nfl", theme="Undrafted RB gems", bid="b1"):
    return {"id": bid, "sport": sport, "content": {"theme": theme, "players": players}}


_FAME = {("nfl", "priest holmes"): 0.95, ("nfl", "star back"): 0.97}


def _threads():
    k = _board([_p(str(i), f"Player {i}", 30.0 - i) for i in range(8)])["content"]
    j = {"stints": [{"teamName": "Bears", "firstYear": 2010, "lastYear": 2012}],
         "answer": {"canonical": "X Y"}}
    w = {"clues": [{"order": i, "text": f"clue {i}"} for i in range(1, 7)], "answer": {"canonical": "X Y"}}
    return [x_assets.thread_resume("nfl", k, k["players"][0], k["players"][1]),
            x_assets.thread_keep4("nfl", k), x_assets.thread_keep4("nfl", k, label="2026 Week 1"),
            x_assets.thread_career("nfl", j), x_assets.thread_whoami("nfl", w)]


@pytest.mark.parametrize("thread", _threads())
def test_threads_fit_and_keep_links_out_of_the_post(thread):
    """X gives a post with a link in its body a fraction of the reach: the link rides in a reply."""
    assert x_assets.x_length(thread["caption"]) <= x_assets.X_LIMIT
    assert "http" not in thread["caption"]
    everything = [thread["caption"], *thread["replies"], thread["reveal"]["text"]]
    assert all(x_assets.x_length(t) <= x_assets.X_LIMIT for t in everything)
    assert all("—" not in t for t in everything), "no em dashes in anything a player reads"
    assert any("ct=x_" in t for t in everything), "the thread carries a tagged store link somewhere"
    assert all("!" not in t for t in everything), "house voice: no exclamation marks"


def test_hidden_answers_stay_out_of_the_post_itself():
    for thread in _threads():
        assert "X Y" not in thread["caption"] and "X Y" not in " ".join(thread["replies"][:1] if thread["alt"] else [])
    resume = _threads()[0]
    assert "Player 0" not in resume["caption"] + resume["alt"]


def test_an_overlong_theme_is_shortened_until_x_accepts_it():
    theme = "Week 1: " + "an extremely long and very specific theme title " * 12
    k = {"theme": theme, "players": [_p(str(i), f"P{i}", 9.0 - i) for i in range(8)]}
    assert x_assets.x_length(x_assets.thread_keep4("nfl", k)["caption"]) <= x_assets.X_LIMIT


def test_resume_wants_a_star_and_close_lines():
    close = _board([_p("a", "Priest Holmes", 400.0), _p("b", "James Wilder", 430.0)])
    no_star = _board([_p("a", "Nobody One", 400.0), _p("b", "Nobody Two", 430.0)])
    blowout = _board([_p("a", "Priest Holmes", 200.0), _p("b", "James Wilder", 430.0)])
    assert x_assets.resume_pairs(close, _FAME)
    assert not x_assets.resume_pairs(no_star, _FAME)
    assert not x_assets.resume_pairs(blowout, _FAME)


def test_resume_prefers_the_star_losing():
    star_loses = _board([_p("a", "Priest Holmes", 400.0), _p("b", "James Wilder", 430.0)], bid="1")
    star_wins = _board([_p("c", "Star Back", 440.0), _p("d", "Some Guy", 430.0)], bid="2")
    board, a, b = x_assets.pick_resume([star_wins, star_loses], _FAME, "any")
    assert board["id"] in ("1", "2")
    top = max(x_assets.resume_pairs(star_loses, _FAME)[0][0], x_assets.resume_pairs(star_wins, _FAME)[0][0])
    assert top == x_assets.resume_pairs(star_loses, _FAME)[0][0]


def test_keep4_posts_need_names_people_know():
    known = _board([_p("a", "Priest Holmes", 1.0), _p("b", "Star Back", 2.0)] + [_p(str(i), f"N{i}", 0.5) for i in range(6)])
    assert x_assets.known_names(known, _FAME) == 2 < x_assets.KEEP4_MIN_KNOWN


def test_nfl_rows_say_week_and_others_say_year():
    assert x_assets._who({"id": "nfl-x", "name": "A", "teamAbbr": "CAR", "week": 1}) == "A (CAR, Week 1)"
    assert x_assets._who({"id": "nba-x", "name": "B", "teamAbbr": "OKC", "week": 67, "seasonYear": 2017}) == "B (OKC, 2017)"


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


def test_a_day_writes_threads_and_a_spec_only_for_images(monkeypatch, tmp_path):
    players = [_p("a", "Priest Holmes", 400.0), _p("b", "James Wilder", 430.0), _p("c", "Star Back", 300.0)] \
        + [_p(str(i), f"N{i}", 10.0 + i) for i in range(5)]
    today = {"id": "t", "sport": "nfl", "content": {"theme": "Today", "players": players}}
    journey = {"id": "j", "sport": "nfl", "content": {"stints": [{"teamName": "Bears"}], "difficulty": "easy",
                                                      "answer": {"canonical": "X Y"}}}
    whoami = {"id": "w", "sport": "nfl", "content": {"clues": [{"order": 1, "text": "c1"}, {"order": 2, "text": "c2"}],
                                                     "answer": {"canonical": "X Y"}}}
    monkeypatch.setattr(x_assets, "daily_boards", lambda d: [today])
    monkeypatch.setattr(x_assets, "archive_boards", lambda d: [_board(players, bid="old")])
    monkeypatch.setattr(x_assets, "dated", lambda d, f: {"nfl": journey if f == "journeyman" else whoami})
    monkeypatch.setattr(x_assets, "fame_index", lambda: {**_FAME, ("nfl", "james wilder"): 0.2})
    monkeypatch.setattr(x_assets, "teams_rows", lambda sports: [])
    assets = x_assets.build(tmp_path, daily="2026-09-17", packs=None, sport=None, draw=False)
    assert [a["kind"] for a in assets] == ["resume", "keep4", "career", "whoami"]
    assert not any("content" in a for a in assets)
    spec = json.loads((tmp_path / "spec.json").read_text())
    assert [p["kind"] for p in spec["posts"]] == ["resume", "keep4", "career"], "whoami is text only"
    assert spec["posts"][0]["puzzle_id"] == "old", "a résumé never comes from today's board"
    assert "REVEAL" in (tmp_path / "captions.md").read_text()


def test_hard_journeyman_subjects_are_not_posted(monkeypatch, tmp_path):
    hard = {"id": "j", "sport": "nfl", "content": {"stints": [{"teamName": "Bears"}], "difficulty": "hard"}}
    monkeypatch.setattr(x_assets, "daily_boards", lambda d: [])
    monkeypatch.setattr(x_assets, "archive_boards", lambda d: [])
    monkeypatch.setattr(x_assets, "dated", lambda d, f: {"nfl": hard} if f == "journeyman" else {})
    monkeypatch.setattr(x_assets, "fame_index", lambda: {})
    monkeypatch.setattr(x_assets, "teams_rows", lambda sports: [])
    assert x_assets.build(tmp_path, daily="2026-09-17", packs=None, sport=None, draw=False) == []


def test_a_fresh_drop_cron_names_exactly_its_own_sports():
    """Both Tuesday crons fire five minutes apart; each must post only its own pack."""
    assert x_assets.cron_sports("30 8 * * 2") == ["nfl"]
    assert x_assets.cron_sports("35 8 * * 2") == ["soccer"]
    assert sorted(x_assets.cron_sports("30 8 * * 3")) == ["baseball", "hockey", "nba"]
    assert x_assets.cron_sports("0 0 * * *") == []


def test_a_failed_upload_skips_that_preview_and_keeps_going(monkeypatch, tmp_path):
    """A Storage 502 on one PNG used to abort the run before Drive and the notification."""
    calls = []

    def storage(method, path, **kw):
        calls.append(path)
        if path.endswith("a.png"):
            raise x_assets.urllib.error.HTTPError(path, 502, "Bad Gateway", {}, None)
        return []

    monkeypatch.setattr(x_assets, "_storage", storage)
    monkeypatch.setattr(x_assets, "_env", lambda: ("https://example.supabase.co", "k"))
    for name in ("a.png", "b.png"):
        (tmp_path / name).write_bytes(b"png")
    assets = [{"file": "a.png"}, {"file": "b.png"}]
    x_assets.publish(tmp_path, assets, "2026-09-17")
    assert "url" not in assets[0] and assets[1]["url"].endswith("/x/2026-09-17/b.png")


def test_gateway_errors_are_retried(monkeypatch):
    attempts = []

    def urlopen(req, timeout):
        attempts.append(1)
        if len(attempts) < 3:
            raise x_assets.urllib.error.HTTPError(req.full_url, 502, "Bad Gateway", {}, None)

        class R:
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return b"{}"
        return R()

    monkeypatch.setattr(x_assets, "_env", lambda: ("https://example.supabase.co", "k"))
    monkeypatch.setattr(x_assets.urllib.request, "urlopen", urlopen)
    monkeypatch.setattr(x_assets.time, "sleep", lambda s: None)
    assert x_assets._storage("POST", "object/marketing/x.png", data=b"x") == {}
    assert len(attempts) == 3


def test_every_post_kind_files_into_a_day_or_pack_folder():
    from tools.marketing import drive
    for kind in ("resume", "keep4", "career", "whoami"):
        folder, _ = drive.place({"kind": kind, "sport": "nfl", "date": "2026-09-16"})
        assert folder[0] == "Daily posts", kind


def test_fit_respects_width_for_a_single_long_word():
    pytest.importorskip("PIL")
    from PIL import Image, ImageDraw
    d = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    f, lines = brand.fit(d, "JOURNEYMAN", brand.anton, 640, 2, 150, 60)
    assert all(brand.text_w(d, ln, f) <= 640 for ln in lines)
