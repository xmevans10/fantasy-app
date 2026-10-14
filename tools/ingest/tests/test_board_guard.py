"""Tests for the keep4 same-title / 5-of-8 overlap guard (`daily_puzzle.BoardIndex`).

Pure: no network, no Supabase. The guard exists because signature novelty only rejects the
identical eight cards, which let Browse fill up with "Ace pitching seasons" x10 and boards
sharing six of eight players under different titles.
"""
import datetime as dt

from tools.ingest.assemble import PuzzleRow
from tools.ingest.daily_puzzle import (BoardIndex, OVERLAP_LIMIT, mint_batch, normalize_title,
                                       pick_novel_puzzle)
from tools.ingest.themes import Theme

TODAY = dt.date(2026, 9, 27)


def _theme(key: str, title: str | None = None, sport: str = "nfl") -> Theme:
    return Theme(key=key, title=title or key, sport=sport, scale="nfl_skill_ppr",
                 positions=frozenset({"WR"}), min_stats={}, columns=[])


def _row(row_id: str, ids: list[str], title: str | None = None, sport: str = "nfl") -> PuzzleRow:
    content = {"id": row_id, "players": [{"id": i} for i in ids]}
    if title is not None:
        content["theme"] = title
    return PuzzleRow(id=row_id, sport=sport, format="keep4", content=content)


def _live(title: str, ids: list[str], sport: str = "nfl") -> dict:
    return {"id": title, "sport": sport, "title": title, "players": [{"id": i} for i in ids]}


EIGHT = [f"p{i}" for i in range(8)]


def test_normalize_title_ignores_case_and_whitespace_only():
    assert normalize_title("  Ace   Pitching\tseasons ") == "ace pitching seasons"
    assert normalize_title("20-goal seasons") != normalize_title("20 goal seasons")


def test_same_title_as_live_board_is_rejected_case_insensitively():
    index = BoardIndex.from_rows([_live("Ace pitching seasons", EIGHT)])
    assert index.conflict("nfl", "ACE  pitching Seasons", ["x"] * 8) == "same title"


def test_same_title_as_retired_board_is_rejected():
    index = BoardIndex.from_rows([], [_live("Elite goal-scoring seasons", EIGHT)])
    assert index.conflict("nfl", "elite goal-scoring seasons", ["q"]) == "same title"


def test_retired_board_players_do_not_block():
    # A retired board isn't shown, so overlapping its cards is harmless; only its title is burned.
    index = BoardIndex.from_rows([], [_live("Old title", EIGHT)])
    assert index.conflict("nfl", "New title", EIGHT) is None


def test_titles_are_scoped_per_sport():
    index = BoardIndex.from_rows([_live("Iron man seasons", EIGHT, sport="soccer")])
    assert index.conflict("nfl", "Iron man seasons", ["z"]) is None


def test_overlap_threshold_is_five_of_eight():
    index = BoardIndex.from_rows([_live("A", EIGHT)])
    four = EIGHT[:4] + ["n1", "n2", "n3", "n4"]
    five = EIGHT[:5] + ["n1", "n2", "n3"]
    assert OVERLAP_LIMIT == 5
    assert index.conflict("nfl", "B", four) is None
    assert index.conflict("nfl", "B", five) == "5+ of 8 same players"


def test_overlap_is_scoped_per_sport():
    index = BoardIndex.from_rows([_live("A", EIGHT, sport="nba")])
    assert index.conflict("nfl", "B", EIGHT) is None


def test_picker_moves_to_next_candidate_when_guard_rejects():
    index = BoardIndex.from_rows([_live("Ace pitching seasons", EIGHT)])
    dup_title = (_theme("gen-a", "Ace pitching seasons"), _row("a", [f"a{i}" for i in range(8)]))
    near_dup = (_theme("gen-b", "Fresh title"), _row("b", EIGHT[:6] + ["b1", "b2"]))
    # Curated-tier key, so it ranks after both niche duplicates and they are tried first.
    clean = (_theme("nfl-clean", "Clean title"), _row("c", [f"c{i}" for i in range(8)]))
    pick = pick_novel_puzzle([dup_title, near_dup, clean], set(), TODAY, guard=index)
    assert pick is not None and pick[0].key == "nfl-clean"
    assert index.rejected[("nfl", "same title")] == 1
    assert index.rejected[("nfl", "5+ of 8 same players")] == 1


def test_row_content_title_wins_over_theme_title():
    # `content.theme` is what Browse shows, so that's what the guard compares.
    index = BoardIndex.from_rows([_live("Shown title", EIGHT)])
    cand = (_theme("gen-x", "Theme title"), _row("x", ["y"] * 8, title="shown TITLE"))
    assert pick_novel_puzzle([cand], set(), TODAY, guard=index) is None


def test_picker_without_guard_is_unchanged():
    cand = (_theme("gen-a", "Ace pitching seasons"), _row("a", EIGHT))
    assert pick_novel_puzzle([cand], set(), TODAY) is not None


def test_guard_returns_none_rather_than_minting_a_duplicate():
    index = BoardIndex.from_rows([_live("Only title", EIGHT)])
    cand = (_theme("gen-a", "Only title"), _row("a", [f"a{i}" for i in range(8)]))
    assert pick_novel_puzzle([cand], set(), TODAY, guard=index) is None


def test_mint_batch_never_mints_the_same_title_twice_in_one_batch():
    theme = _theme("nfl-curated", "Curated title")
    rows = [_row(f"r{i}", [f"r{i}-{j}" for j in range(8)]) for i in range(3)]
    other = _theme("gen-other", "Other title")
    other_row = _row("o", [f"o{j}" for j in range(8)])
    by_sport = {"nfl": [(theme, r) for r in rows] + [(other, other_row)]}
    targets = [(TODAY + dt.timedelta(days=d), "nfl") for d in range(3)]
    minted = mint_batch(by_sport, set(), targets, guard=BoardIndex())
    titles = [t.title for _, t, _, _ in minted]
    assert sorted(titles) == ["Curated title", "Other title"]   # third day runs dry, not dup


def test_mint_batch_never_mints_near_duplicates_of_its_own_picks():
    a = (_theme("gen-a", "A"), _row("a", EIGHT))
    b = (_theme("gen-b", "B"), _row("b", EIGHT[:5] + ["b1", "b2", "b3"]))
    targets = [(TODAY, "nfl"), (TODAY + dt.timedelta(days=1), "nfl")]
    minted = mint_batch({"nfl": [a, b]}, set(), targets, guard=BoardIndex())
    assert len(minted) == 1
