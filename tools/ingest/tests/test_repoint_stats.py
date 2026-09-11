"""The retroactive card fix must land on exactly what a fresh mint would have produced."""
from __future__ import annotations

import json

from tools.ingest import curation, generate, repoint_stats
from tools.ingest.themes import KEEP4_THEMES, format_columns


# A stat bag broad enough that every sport's canonical keys resolve to a distinctive number,
# so a mismatch in ORDER shows up as a value mismatch and not just a label one.
RAW = {
    "passing_yards": 4671.0, "passing_tds": 35.0, "interceptions": 11.0,
    "rushing_yards": 24.0, "rushing_tds": 1.0, "receptions": 110.0,
    "receiving_yards": 1338.0, "receiving_tds": 12.0, "targets": 152.0,
    "ypr": 12.2, "ypc": 4.4, "carries": 210.0, "games": 17.0,
    "completions": 364.0, "attempts": 542.0, "completion_pct": 67.2,
    "goals": 24.0, "assists": 9.0, "appearances": 38.0, "clean_sheets": 15.0,
    "points": 121.0, "plus_minus": 22.0, "shots": 301.0, "shooting_pct": 11.4,
    "pp_points": 41.0, "wins": 38.0, "gaa": 2.14, "save_pct": 0.928, "shutouts": 6.0,
    "home_runs": 41.0, "rbi": 118.0, "avg": 0.311, "hits": 189.0, "era": 2.28,
    "strike_outs": 243.0, "earned_runs": 58.0, "innings_pitched": 213.1,
}


def _all_themes():
    themes = list(KEEP4_THEMES)
    for cfg in curation.SPORTS.values():
        themes += generate._candidates(cfg)
    return themes


def test_labels_are_unambiguous():
    """The repoint reads a frozen card's stat keys back out of its LABELS. Two stats sharing
    one label in a sport would make that impossible — and would already have made the card
    ambiguous to a human reading it."""
    for sport, by_label in repoint_stats.LABELS.items():
        assert len(by_label) == len(set(by_label.values())), \
            f"{sport} has two stat keys under one label"


def test_repointed_card_equals_a_fresh_mint():
    """For every theme shape the pipeline can mint, a card the repoint decides is broken must
    rebuild to byte-identical output to `format_columns` — the fresh-mint path.

    This is the whole safety argument for not reconstructing the theme in repoint_stats: the
    two paths are allowed to differ only on cards that aren't broken, which are never written.
    """
    checked = 0
    for theme in _all_themes():
        if len(theme.positions) <= 1:
            continue
        for position in sorted(theme.positions):
            frozen = format_columns(theme, RAW)          # what the OLD, unsliced mint wrote
            if not repoint_stats.card_is_broken(theme.sport, position, frozen):
                continue
            rebuilt = repoint_stats.rebuild_card(theme.sport, position, theme.grain, frozen, RAW)
            assert rebuilt == format_columns(theme, RAW, position), (
                f"{theme.key}/{position}: repoint disagrees with a fresh mint")
            checked += 1
    assert checked, "no broken shapes exercised — the fixture or the guard has drifted"


def test_a_good_card_is_never_touched():
    """A card whose every column its position does produce must be left exactly alone —
    the repoint may not rewrite a theme's curated emphasis into the canonical line."""
    wr = next(t for t in KEEP4_THEMES if t.key == "nfl-wr-receiving")
    frozen = format_columns(wr, RAW)
    assert not repoint_stats.card_is_broken("nfl", "WR", frozen)

    snipers = next(t for t in KEEP4_THEMES if t.key == "hockey-modern-snipers")
    assert not repoint_stats.card_is_broken("hockey", "C", format_columns(snipers, RAW))

    nba = next(t for t in KEEP4_THEMES if t.key == "nba-scorers")
    assert not repoint_stats.card_is_broken("nba", "G", format_columns(nba, RAW))


def test_unknown_labels_are_left_alone():
    """A label this build can't resolve came from some other version of the catalog. Guessing
    about it would rewrite cards that are fine, so it must read as "not broken"."""
    stats = [{"label": "Weird Legacy Stat", "value": "12"}]
    assert not repoint_stats.card_is_broken("nfl", "TE", stats)


def test_kelce_card_is_rebuilt_from_real_stats():
    """The literal reported card: the NFL daily for 2026-09-06 served this exact stat line."""
    frozen = [{"label": "Pass Yds", "value": "0"}, {"label": "Pass TD", "value": "0"},
              {"label": "Rush Yds", "value": "5"}, {"label": "Rush TD", "value": "0"},
              {"label": "Rec", "value": "110"}]
    assert repoint_stats.card_is_broken("nfl", "TE", frozen)
    rebuilt = repoint_stats.rebuild_card("nfl", "TE", "season", frozen, {
        "receiving_yards": 1338.0, "receptions": 110.0, "receiving_tds": 12.0,
        "rushing_yards": 5.0, "passing_yards": 0.0,
    })
    assert rebuilt == [{"label": "Rec Yds", "value": "1,338"},
                       {"label": "Rec", "value": "110"},
                       {"label": "Rec TD", "value": "12"}]


def test_keeper_card_is_rebuilt_to_the_keeper_line():
    frozen = [{"label": "Clean Sheets", "value": "14"}, {"label": "Apps", "value": "34"},
              {"label": "Goals", "value": "0"}, {"label": "Assists", "value": "0"}]
    assert repoint_stats.card_is_broken("soccer", "GK", frozen)
    rebuilt = repoint_stats.rebuild_card("soccer", "GK", "season", frozen,
                                         {"clean_sheets": 14.0, "appearances": 34.0})
    assert rebuilt == [{"label": "Clean Sheets", "value": "14"},
                       {"label": "Apps", "value": "34"}]


def test_a_card_with_no_catalog_row_is_left_alone(tmp_path):
    """A rebuild needs real stats. With none, the honest move is to leave the wrong-but-real
    numbers rather than write a card of zeroes."""
    content = {"sport": "nfl", "grain": "season", "players": [
        {"id": "nfl-missing-2023", "stats": [{"label": "Pass Yds", "value": "0"},
                                             {"label": "Rec", "value": "110"}]}]}
    out, fixed = repoint_stats.repoint_content(content, catalog={})
    assert fixed == 0 and out == content


def test_bundle_repoint_is_idempotent(tmp_path):
    """A second pass must find nothing — otherwise the daily workflow rewrites rows forever."""
    puzzles = tmp_path / "keep4_puzzles.json"
    catalog = tmp_path / "player_seasons.json"
    puzzles.write_text(json.dumps([{
        "id": "t-00", "sport": "nfl", "grain": "season", "theme": "Test",
        "players": [{"id": "nfl-kelce-2022", "name": "Travis Kelce",
                     "stats": [{"label": "Pass Yds", "value": "0"},
                               {"label": "Rec", "value": "110"}]}],
    }]), encoding="utf-8")
    catalog.write_text(json.dumps([{
        "id": "nfl-kelce-2022", "position": "TE",
        "stats": {"receiving_yards": 1338.0, "receptions": 110.0, "receiving_tds": 12.0},
    }]), encoding="utf-8")

    assert repoint_stats.repoint_bundle(puzzles, catalog) == 1
    assert repoint_stats.repoint_bundle(puzzles, catalog) == 0
    rebuilt = json.loads(puzzles.read_text(encoding="utf-8"))[0]["players"][0]["stats"]
    assert [s["label"] for s in rebuilt] == ["Rec Yds", "Rec", "Rec TD"]


def test_a_colliding_catalog_row_is_declined_not_rewritten():
    """`baseball-babe-ruth-career` is minted as his hitting career but the catalog row under
    that id holds his pitching career. Without the corroboration guard the repoint would see
    position "P", call the hitting card broken, and print "W 94 · ERA 2.28 · K 488" onto a
    career-hitters board. Real numbers from the wrong career are worse than the badly-chosen
    ones already there, so the card must be declined and reported."""
    frozen = [{"label": "HR", "value": "714"}, {"label": "RBI", "value": "2,213"},
              {"label": "AVG", "value": "0.342"}, {"label": "OPS", "value": "1.164"},
              {"label": "R", "value": "2,174"}]
    pitching = {"wins": 94.0, "era": 2.276, "strike_outs": 488.0,
                "innings_pitched": 1221.333, "earned_runs": 309.0, "base_on_balls": 441.0}
    assert repoint_stats.card_is_broken("baseball", "P", frozen)      # position says pitcher
    assert not repoint_stats.corroborated("baseball", frozen, pitching)

    content = {"sport": "baseball", "grain": "career", "players": [
        {"id": "baseball-babe-ruth-career", "stats": frozen}]}
    skipped: list[str] = []
    out, fixed = repoint_stats.repoint_content(
        content, {"baseball-babe-ruth-career": {"position": "P", "stats": pitching}}, skipped)
    assert fixed == 0 and out == content
    assert skipped == ["baseball-babe-ruth-career"]


def test_a_matching_catalog_row_corroborates():
    """The ordinary case: the frozen card and the catalog row agree on a number, so the
    rebuild is allowed to proceed."""
    frozen = [{"label": "Pass Yds", "value": "0"}, {"label": "Rec", "value": "110"}]
    assert repoint_stats.corroborated(
        "nfl", frozen, {"receptions": 110.0, "receiving_yards": 1338.0})
    # Agreement only on a zero proves nothing — two unrelated rows share plenty of zeroes.
    assert not repoint_stats.corroborated(
        "nfl", [{"label": "Pass Yds", "value": "0"}], {"passing_yards": 0.0})
