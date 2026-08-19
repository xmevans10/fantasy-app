"""Tests for the daily novel-puzzle picker (pure — no network, no Supabase)."""
import datetime as dt

from tools.ingest.assemble import PuzzleRow
from tools.ingest.daily_puzzle import _signature, group_by_sport, mint_batch, pick_novel_puzzle
from tools.ingest.themes import Theme

TODAY = dt.date(2026, 1, 1)


def _theme(key: str, sport: str = "nfl") -> Theme:
    return Theme(key=key, title=key, sport=sport, scale="nfl_skill_ppr",
                positions=frozenset({"WR"}), min_stats={}, columns=[])


def _row(row_id: str, player_ids: list[str], sport: str = "nfl") -> PuzzleRow:
    return PuzzleRow(id=row_id, sport=sport, format="keep4",
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


def _targets(dates: list[dt.date], sports: list[str]) -> list[tuple[dt.date, str]]:
    return [(d, s) for d in dates for s in sports]


def test_mint_batch_never_repeats_a_signature_within_the_same_batch():
    theme = _theme("gen-wr-test")
    rows = [_row(f"r{i}", [f"p{i}-{j}" for j in range(8)]) for i in range(20)]
    by_sport = group_by_sport([(theme, r) for r in rows])
    dates = [TODAY + dt.timedelta(days=i) for i in range(5)]
    minted = mint_batch(by_sport, set(), _targets(dates, ["nfl"]))
    sigs = [sig for _, _, _, sig in minted]
    assert len(minted) == 5
    assert len(set(sigs)) == 5   # every date in the batch got a distinct signature


def test_mint_batch_skips_exhausted_slots_instead_of_minting_duplicates():
    theme = _theme("gen-wr-test")
    rows = [_row(f"r{i}", [f"p{i}-{j}" for j in range(8)]) for i in range(3)]
    by_sport = group_by_sport([(theme, r) for r in rows])
    dates = [TODAY + dt.timedelta(days=i) for i in range(10)]
    minted = mint_batch(by_sport, set(), _targets(dates, ["nfl"]))
    assert len(minted) == 3   # only 3 distinct signatures exist to give out


def test_mint_batch_respects_signatures_served_before_the_batch_started():
    theme = _theme("gen-wr-test")
    rows = [_row(f"r{i}", [f"p{i}-{j}" for j in range(8)]) for i in range(5)]
    by_sport = group_by_sport([(theme, r) for r in rows])
    pre_served = {_signature(theme.key, rows[i]) for i in range(3)}
    dates = [TODAY + dt.timedelta(days=i) for i in range(2)]
    minted = mint_batch(by_sport, set(pre_served), _targets(dates, ["nfl"]))
    assert len(minted) == 2
    for _, _, _, sig in minted:
        assert sig not in pre_served


def test_mint_batch_mints_one_row_per_sport_per_date():
    candidates = []
    for sport in ["nfl", "nba"]:
        theme = _theme(f"gen-{sport}-test", sport=sport)
        candidates += [(theme, _row(f"{sport}-r{i}", [f"{sport}-p{i}-{j}" for j in range(8)],
                                    sport=sport)) for i in range(10)]
    dates = [TODAY, TODAY + dt.timedelta(days=1)]
    minted = mint_batch(group_by_sport(candidates), set(), _targets(dates, ["nfl", "nba"]))
    assert len(minted) == 4
    slots = {(date, theme.sport) for date, theme, _, _ in minted}
    assert slots == {(d, s) for d in dates for s in ["nfl", "nba"]}
    # Every minted row's content matches its slot's sport — no cross-sport leakage.
    for _, theme, row, _ in minted:
        assert row.sport == theme.sport


def test_mint_batch_one_sports_exhaustion_never_blocks_another_sport():
    thin_theme = _theme("gen-nfl-thin", sport="nfl")
    deep_theme = _theme("gen-nba-deep", sport="nba")
    candidates = [(thin_theme, _row("nfl-only", [f"p{j}" for j in range(8)]))]
    candidates += [(deep_theme, _row(f"nba-r{i}", [f"nba-p{i}-{j}" for j in range(8)],
                                     sport="nba")) for i in range(10)]
    dates = [TODAY + dt.timedelta(days=i) for i in range(3)]
    minted = mint_batch(group_by_sport(candidates), set(), _targets(dates, ["nfl", "nba"]))
    by_sport = {}
    for _, theme, _, _ in minted:
        by_sport[theme.sport] = by_sport.get(theme.sport, 0) + 1
    assert by_sport == {"nfl": 1, "nba": 3}   # nfl exhausts after day 1; nba keeps minting


def test_group_by_sport_preserves_candidate_order_within_a_sport():
    niche = _theme("gen-wr-niche")
    curated = _theme("nfl-wr-receiving")
    pairs = [(niche, _row("n", ["a"])), (curated, _row("c", ["b"]))]
    grouped = group_by_sport(pairs)
    assert [t.key for t, _ in grouped["nfl"]] == ["gen-wr-niche", "nfl-wr-receiving"]


# ── Theme cooldown ───────────────────────────────────────────────────────────────
# Signature-novelty alone let one theme's many variants monopolize a sport: live on
# 2026-08-18, baseball had served "Ace pitching seasons" 9 times in 23 days with a different
# eight cards each time. These cover the soft ranking penalty that fixes it.

def test_cooldown_prefers_a_theme_the_sport_has_not_served_recently():
    hot = _theme("baseball-ace-pitchers", sport="baseball")
    cold = _theme("baseball-power-hitters", sport="baseball")
    # Hot theme first in candidate order, so only the cooldown can dislodge it.
    candidates = [(hot, _row("hot", [f"h{i}" for i in range(8)], sport="baseball")),
                  (cold, _row("cold", [f"c{i}" for i in range(8)], sport="baseball"))]
    theme, _, _ = pick_novel_puzzle(candidates, set(), TODAY, {"baseball-ace-pitchers"})
    assert theme.key == "baseball-power-hitters"


def test_cooldown_never_blocks_a_mint_when_every_theme_is_on_it():
    hot = _theme("baseball-ace-pitchers", sport="baseball")
    candidates = [(hot, _row("hot", [f"h{i}" for i in range(8)], sport="baseball"))]
    pick = pick_novel_puzzle(candidates, set(), TODAY, {"baseball-ace-pitchers"})
    assert pick is not None and pick[0].key == "baseball-ace-pitchers"


def test_cooldown_still_yields_to_signature_novelty():
    # A cold theme whose only variant was already served must not be picked over a hot theme
    # with an unserved one — signature-novelty is the hard guarantee, cooldown is a preference.
    hot = _theme("t-hot", sport="nba")
    cold = _theme("t-cold", sport="nba")
    hot_row = _row("hot", [f"h{i}" for i in range(8)], sport="nba")
    cold_row = _row("cold", [f"c{i}" for i in range(8)], sport="nba")
    served = {_signature("t-cold", cold_row)}
    theme, _, _ = pick_novel_puzzle([(cold, cold_row), (hot, hot_row)], served, TODAY, {"t-hot"})
    assert theme.key == "t-hot"


def test_mint_batch_spreads_themes_across_its_own_days():
    # Three days, two themes with plenty of variants each: a batch must alternate rather than
    # spend all three days on whichever theme sorts first.
    a = _theme("s-a", sport="soccer")
    b = _theme("s-b", sport="soccer")
    candidates = [(a, _row(f"a{i}", [f"a{i}-{j}" for j in range(8)], sport="soccer"))
                  for i in range(5)]
    candidates += [(b, _row(f"b{i}", [f"b{i}-{j}" for j in range(8)], sport="soccer"))
                   for i in range(5)]
    dates = [TODAY + dt.timedelta(days=i) for i in range(3)]
    minted = mint_batch(group_by_sport(candidates), set(), _targets(dates, ["soccer"]))
    keys = [theme.key for _, theme, _, _ in minted]
    assert len(minted) == 3
    assert len(set(keys)) == 2          # both themes used; no single-theme run
    assert keys[0] != keys[1]           # consecutive days never repeat a theme


def test_mint_batch_honours_history_cooldown_passed_in():
    a = _theme("s-a", sport="soccer")
    b = _theme("s-b", sport="soccer")
    candidates = [(a, _row("a", [f"a{j}" for j in range(8)], sport="soccer")),
                  (b, _row("b", [f"b{j}" for j in range(8)], sport="soccer"))]
    minted = mint_batch(group_by_sport(candidates), set(), _targets([TODAY], ["soccer"]),
                        {"soccer": {"s-a"}})
    assert [theme.key for _, theme, _, _ in minted] == ["s-b"]
