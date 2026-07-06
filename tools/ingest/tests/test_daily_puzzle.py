"""Tests for the daily novel-puzzle picker (pure — no network, no Supabase)."""
import datetime as dt

from tools.ingest.assemble import PuzzleRow
from tools.ingest.daily_puzzle import _signature, pick_novel_puzzle
from tools.ingest.themes import Theme

TODAY = dt.date(2026, 1, 1)


def _theme(key: str) -> Theme:
    return Theme(key=key, title=key, sport="nfl", scale="nfl_skill_ppr",
                positions=frozenset({"WR"}), min_stats={}, columns=[])


def _row(row_id: str, player_ids: list[str]) -> PuzzleRow:
    return PuzzleRow(id=row_id, sport="nfl", format="keep4",
                     content={"id": row_id, "players": [{"id": pid} for pid in player_ids]})


def test_signature_is_order_independent_in_player_ids():
    row_a = _row("r", ["b", "a", "c"])
    row_b = _row("r", ["c", "b", "a"])
    assert _signature("t", row_a) == _signature("t", row_b)


def test_signature_differs_across_themes_for_the_same_players():
    row = _row("r", ["a", "b"])
    assert _signature("theme-1", row) != _signature("theme-2", row)


def test_pick_novel_puzzle_skips_served_signatures():
    theme = _theme("gen-wr-test")
    rows = [_row(f"r{i}", [f"p{i}-{j}" for j in range(8)]) for i in range(3)]
    candidates = [(theme, r) for r in rows]
    served = {_signature(theme.key, rows[0]), _signature(theme.key, rows[1])}
    pick = pick_novel_puzzle(candidates, served, TODAY)
    assert pick is not None
    _, _, sig = pick
    assert sig == _signature(theme.key, rows[2])


def test_pick_novel_puzzle_prefers_niche_over_curated():
    niche = _theme("gen-wr-niche")
    curated = _theme("nfl-wr-receiving")
    niche_row = _row("n", [f"n{i}" for i in range(8)])
    curated_row = _row("c", [f"c{i}" for i in range(8)])
    candidates = [(curated, curated_row), (niche, niche_row)]
    pick = pick_novel_puzzle(candidates, set(), TODAY)
    assert pick[0].key == "gen-wr-niche"


def test_pick_novel_puzzle_returns_none_when_exhausted():
    theme = _theme("gen-wr-test")
    row = _row("r", [f"p{j}" for j in range(8)])
    served = {_signature(theme.key, row)}
    assert pick_novel_puzzle([(theme, row)], served, TODAY) is None


def test_pick_novel_puzzle_is_deterministic_for_the_same_date():
    theme = _theme("gen-wr-test")
    rows = [_row(f"r{i}", [f"p{i}-{j}" for j in range(8)]) for i in range(20)]
    candidates = [(theme, r) for r in rows]
    pick_a = pick_novel_puzzle(candidates, set(), TODAY)
    pick_b = pick_novel_puzzle(candidates, set(), TODAY)
    assert pick_a[2] == pick_b[2]
