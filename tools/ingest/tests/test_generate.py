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


# ── Cross-sport generator ────────────────────────────────────────────────────────

def test_nfl_registry_entry_matches_the_legacy_module_level_config():
    # NFL's generated keys are recorded in `puzzle_history` signatures, so the registry must
    # be a pure re-expression of the old POSITIONS/QUIRKS/DECADES globals, not a rewrite.
    nfl = curation.SPORTS["nfl"]
    assert nfl.positions is curation.POSITIONS and nfl.quirks is curation.QUIRKS
    assert [s.key for s in nfl.slices] == [str(d) if d else "all" for d in curation.DECADES]
    assert all(t.key.startswith(("gen-", "gen2-")) and t.sport == "nfl"
               for t in generate._candidates(nfl))
    # ...and no sport-namespaced prefix, which would change every NFL key.
    assert not any(t.key.startswith("gen-nfl-") for t in generate._candidates(nfl))


def test_every_other_sport_namespaces_its_keys_by_sport():
    for name, cfg in curation.SPORTS.items():
        if cfg.sport == "nfl":
            continue
        for t in generate._candidates(cfg):
            assert t.key.startswith(f"gen-{cfg.sport}-"), (name, t.key)
            assert t.sport == cfg.sport


def test_position_scoped_quirks_only_pair_with_their_own_cohort():
    # "Goal-scoring" is an oddity for a centre-back and a tautology for a striker: crossed with
    # the forward spec it built "Goal-scoring forward seasons", a filter every card already met.
    soccer = curation.SPORTS["soccer"]
    keys = {t.key for t in generate._candidates(soccer) + generate._pairwise_candidates(soccer)}
    scoped = [k for k in keys if "scoring-defender" in k or "-wall" in k]
    assert scoped, "expected the back-line quirks to still generate themes"
    assert all("-back-" in k for k in scoped)


def test_unscoped_quirks_still_cross_every_cohort():
    # The NBA cross-products are the point — a guard with 12 rebounds, a big man with 8 assists.
    keys = {t.key for t in generate._candidates(curation.SPORTS["nba"])}
    assert any(k.startswith("gen-nba-g-") and k.endswith("-glass") for k in keys)
    assert any(k.startswith("gen-nba-big-") and k.endswith("-dime") for k in keys)


def test_quirk_columns_are_promoted_to_the_front_of_the_card():
    # A board titled "20-20 club seasons" has to actually show SB.
    hitters = curation.SPORTS["baseball"]
    theme = next(t for t in generate._candidates(hitters) if t.key.endswith("-all-power-speed"))
    assert theme.columns[0].stat == "stolen_bases"
    assert len(theme.columns) <= generate._MAX_COLUMNS
    assert len({c.stat for c in theme.columns}) == len(theme.columns)   # no duplicate stat


def test_all_niche_candidates_skips_sports_absent_from_the_pull():
    # A run that pulled only NFL must not spend time building five sports' candidate spaces.
    nfl_only = [RawSeason(name=f"P{i}", team_abbr="X", season_year=2015, sport="nfl",
                          position="WR", stats={"receiving_yards": 1200.0}, headshot="h")
                for i in range(3)]
    assert all(t.sport == "nfl" for t in generate.all_niche_candidates(nfl_only))


# ── Franchise + era slices ───────────────────────────────────────────────────────

def _mlb(name, team, year, hr=30.0):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport="baseball",
                     position="H", stats={"home_runs": hr, "plate_appearances": 600.0},
                     headshot="h")


def test_team_slices_rank_franchises_by_actual_coverage():
    """Derived from the data, not a hardcoded roster — teams relocate, rename and get added,
    and a literal list would rot silently (AGENTS.md §2)."""
    cfg = curation.SPORTS["baseball"]
    seasons = ([_mlb(f"Yankee {i}", "NYY", 1990 + i) for i in range(30)]
               + [_mlb(f"Met {i}", "NYM", 1990 + i) for i in range(10)]
               + [_mlb(f"Ray {i}", "TB", 1990 + i) for i in range(2)])
    slices = generate.team_slices(cfg, seasons)
    keys = [s.key for s in slices]
    assert keys[0].startswith("nyy") and keys[1].startswith("nym")
    assert all(f.field == "team" for s in slices for f in s.filters if f.field == "team")


def test_team_slices_ignore_career_and_game_rows():
    # A franchise's game-grain volume says nothing about whether it can field eight close
    # SEASONS, and career rows are aggregates, not seasons.
    cfg = curation.SPORTS["baseball"]
    def variant(**kw):
        base = dict(name="Noise", team_abbr="TB", season_year=2000, sport="baseball",
                    position="H", stats={"home_runs": 30.0}, headshot="h")
        return RawSeason(**{**base, **kw})

    seasons = [_mlb("Real Season", "NYY", 2000)]
    noisy = [variant(week=5), variant(career=True)] * 20
    slices = generate.team_slices(cfg, seasons + noisy)
    assert [s.key for s in slices][0].startswith("nyy")


def test_team_slices_are_off_where_team_is_not_a_franchise():
    # Tennis stores NATIONALITY in team_abbr and already slices on it explicitly.
    assert generate.team_slices(curation.SPORTS["tennis"], []) == ()


def test_combine_crosses_an_era_with_a_franchise_and_reads_as_a_sentence():
    era = curation.decade_slices([1990])[0]
    team = curation.Slice(key="nyy", filters=(Filter("team", "eq", "NYY"),), suffix=" — NYY")
    both = curation.combine(era, team)
    assert both.prefix == "1990s " and both.suffix == " — NYY"
    # Both predicates survive the cross — that is the whole point of the axis.
    assert {(f.field, f.value) for f in both.filters} == {("decade", 1990), ("team", "NYY")}


def test_team_slices_produce_themes_that_name_the_franchise():
    cfg = curation.SPORTS["baseball"]
    seasons = [_mlb(f"Yankee {i}", "NYY", 1990 + i) for i in range(30)]
    themes = generate._candidates(cfg, generate.team_slices(cfg, seasons))
    titles = [t.title for t in themes]
    assert any(t.endswith("— NYY") for t in titles), titles[:3]
    assert any("1990s" in t and t.endswith("— NYY") for t in titles), "expected an era x franchise cut"
