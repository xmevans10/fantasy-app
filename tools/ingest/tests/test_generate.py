"""Tests for filter/grain handling in assemble + the generator viability gate.

Synthetic seasons only (no network)."""
from tools.ingest import assemble, curation, generate
from tools.ingest.models import RawSeason
from tools.ingest.themes import Filter, StatColumn, Theme

_COLS = [StatColumn("receiving_yards", "Rec Yds", "comma_int")]


def _wr(name, yards, *, week=None, college=None, headshot="h"):
    meta = {"college": college} if college else {}
    return RawSeason(name=name, team_abbr="X", season_year=2015, sport="nfl",
                     position="WR", stats={"receiving_yards": float(yards), "receptions": 80.0,
                                           "receiving_tds": 8.0},
                     headshot=headshot, week=week, opponent="DEN" if week else "", meta=meta)


def _theme(**kw):
    base = dict(key="t", title="T", sport="nfl", scale="nfl_skill_ppr",
                positions=frozenset({"WR"}), min_stats={}, columns=_COLS)
    base.update(kw)
    return Theme(**base)


def _pool(n_start=1000):
    # 10 WR seasons with descending yards → distinct, close grades + clean boundary.
    return [_wr(f"Player {i}", n_start + i * 60) for i in range(10)]


def test_filters_narrow_the_pool_below_viable():
    seasons = _pool()
    # Only 3 share the college → fewer than 8 candidates → no puzzle built.
    for s in seasons[:3]:
        s.meta["college"] = "LSU"
    theme = _theme(filters=(Filter("college", "eq", "LSU"),))
    assert assemble.build_keep4_rows(theme, seasons) == []


def test_no_filters_builds_a_puzzle():
    rows = assemble.build_keep4_rows(_theme(), _pool())
    assert rows and len(rows[0].content["players"]) == 8


def test_season_theme_excludes_game_rows():
    seasons = _pool()
    # Add 8 game-grain rows for distinct players; a season theme must ignore them.
    games = [_wr(f"Gamer {i}", 200, week=10) for i in range(8)]
    theme = _theme(grain="season")
    rows = assemble.build_keep4_rows(theme, seasons + games)
    names = {p["name"] for r in rows for p in r.content["players"]}
    assert not any(n.startswith("Gamer") for n in names)


def test_game_theme_excludes_season_rows_and_carries_context():
    games = [_wr(f"Gamer {i}", 150 + i * 20, week=12) for i in range(10)]
    theme = _theme(grain="game", scale="nfl_skill_ppr")
    rows = assemble.build_keep4_rows(theme, _pool() + games)
    assert rows
    players = rows[0].content["players"]
    assert all(p["name"].startswith("Gamer") for p in players)
    assert all(p["week"] == 12 and p["opponent"] == "DEN" for p in players)


def test_default_max_variants_is_one():
    # Regression: themes used to default to 3 near-duplicate variants per theme.
    # A large, evenly-spread pool would yield several windows if not capped to 1.
    seasons = [_wr(f"Player {i}", 1000 + i * 30) for i in range(40)]
    rows = assemble.build_keep4_rows(_theme(), seasons)
    assert len(rows) == 1


def test_max_variants_override_returns_distinct_windows():
    # The daily novel-puzzle picker asks for many windows per theme; each must be a genuinely
    # distinct player set, not the same 8 players repeated.
    seasons = [_wr(f"Player {i}", 1000 + i * 30) for i in range(40)]
    rows = assemble.build_keep4_rows(_theme(), seasons, max_variants=5)
    assert len(rows) == 5
    signatures = {tuple(sorted(p["id"] for p in r.content["players"])) for r in rows}
    assert len(signatures) == 5


def test_max_variants_override_none_falls_back_to_theme_default():
    seasons = [_wr(f"Player {i}", 1000 + i * 30) for i in range(40)]
    rows = assemble.build_keep4_rows(_theme(), seasons, max_variants=None)
    assert len(rows) == 1


# ── Niche generator: bio quirks + pairwise combos ────────────────────────────────

def test_redundant_pair_rejects_same_axis_combos():
    by_key = {q.key: q for q in curation.QUIRKS}
    assert curation.redundant_pair(by_key["young"], by_key["vet"])          # both age
    assert curation.redundant_pair(by_key["undrafted"], by_key["day3"])     # both draft
    assert curation.redundant_pair(by_key["sub6"], by_key["towering"])      # both size
    assert not curation.redundant_pair(by_key["undrafted"], by_key["sub6"])  # draft x size


def test_pairwise_candidates_skip_redundant_quirk_pairs():
    keys = {t.key for t in generate._pairwise_candidates()}
    assert not any(k.endswith("-young-vet") for k in keys)
    assert not any(k.endswith("-undrafted-day3") for k in keys)
    assert any(k.endswith("-undrafted-sub6") for k in keys)


def test_weight_filters_are_position_relative():
    wr = curation.weight_filters(curation.POSITIONS["WR"])["lightweight"][0]
    qb = curation.weight_filters(curation.POSITIONS["QB"])["lightweight"][0]
    assert wr.value != qb.value


def _bio_wr(name: str, yards: float, *, undrafted: bool = True, height_in: int = 70):
    meta: dict[str, str] = {"height_in": str(height_in)}
    if not undrafted:
        meta["draft_round"] = "3"
    return RawSeason(name=name, team_abbr="X", season_year=2015, sport="nfl", position="WR",
                     stats={"receiving_yards": yards, "receptions": 80.0, "receiving_tds": 8.0},
                     headshot="h", meta=meta)


def test_all_niche_candidates_finds_a_viable_pairwise_combo():
    # 10 undrafted, sub-6-foot WRs, well above the WR floor (600 yds) and each other's
    # neighbor by a clean margin → both quirks match everyone, so the AND'd pool is a fair
    # 8-close-seasons puzzle and the combo should survive the viability gate.
    seasons = [_bio_wr(f"Player {i}", 1200 - i * 40) for i in range(10)]
    niche = generate.all_niche_candidates(seasons)
    assert any(t.key == "gen2-wr-all-undrafted-sub6" for t in niche)
