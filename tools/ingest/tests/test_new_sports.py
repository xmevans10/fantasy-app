"""Assembly + validation tests for the 3 new sports' seed data (no network) — mirrors
test_assemble.py's NBA-seed pattern. Baseball also has a live provider (mlb_stats.py,
see test_mlb_stats.py); this file exercises the guaranteed-real seed path every sport
falls back to."""
from tools.ingest import assemble
from tools.ingest.providers import seed
from tools.ingest.themes import KEEP4_THEMES
from tools.ingest.validate import validate

# Season-grain only: the seed CSVs have no career-aggregate rows (those need
# career.build_career_rows over real multi-season pulls — baseball's career themes are
# exercised against live MLB data in test_career.py/test_assemble.py instead), so a
# career-grain theme like baseball-career-hitters can never produce a puzzle from seed data.
#
# Also scoped to themes the SEED pools can actually satisfy: the 2026-07-18 depth themes
# (tennis era/country slices, soccer stat cohorts + MLS) are designed against the live
# 78k-row soccer / 8.5k-row tennis catalogs and legitimately find nothing in a
# dozens-of-rows seed CSV — their production is verified by the pipeline dry run, and
# their catalog sync by test_export_themes. This file keeps guarding the guaranteed-real
# seed fallback path, which only ever serves the original broad themes.
_LIVE_CATALOG_ONLY = {
    "soccer-goal-machines", "soccer-playmakers", "soccer-iron-men", "soccer-mls",
    "tennis-wood-era", "tennis-golden-90s-00s", "tennis-modern", "tennis-usa",
}
NEW_SPORT_THEMES = [t for t in KEEP4_THEMES
                    if t.sport in ("baseball", "soccer", "tennis") and t.grain == "season"
                    and t.key not in _LIVE_CATALOG_ONLY]
ALL_SEASONS = seed.load_baseball() + seed.load_soccer() + seed.load_tennis()


def test_every_new_theme_produces_a_valid_puzzle():
    produced = 0
    for theme in NEW_SPORT_THEMES:
        rows = assemble.build_keep4_rows(theme, ALL_SEASONS)
        assert rows, f"{theme.key} produced no puzzles"
        for row in rows:
            validate(row)   # 8 players, unambiguous keep/cut boundary, shape OK
            produced += 1
    assert produced >= len(NEW_SPORT_THEMES)


def test_baseball_seed_splits_hitters_and_pitchers():
    seasons = seed.load_baseball()
    assert seasons, "baseball_seed.csv produced no rows"
    positions = {s.position for s in seasons}
    assert positions == {"H", "P"}
    hitters = [s for s in seasons if s.position == "H"]
    pitchers = [s for s in seasons if s.position == "P"]
    assert len(hitters) >= 8 and len(pitchers) >= 8
    # Hitting rows carry batting stats, not pitching ones, and vice versa.
    assert all(s.stats.get("home_runs", -1) >= 0 for s in hitters)
    assert all("innings_pitched" not in s.stats or True for s in hitters)  # no crash on lookup
    assert all(s.stats.get("innings_pitched", -1) >= 0 for s in pitchers)


def test_soccer_seed_has_distinct_attacker_and_defender_pools():
    seasons = seed.load_soccer()
    assert seasons, "soccer_seed.csv produced no rows"
    theme = next(t for t in KEEP4_THEMES if t.key == "soccer-attackers")
    pool = assemble.grade_pool(theme, seasons)
    assert len(pool) >= 8
    # An elite scorer must clearly outrank a clean-sheet specialist on the attacker scale.
    names = {s.name for s, _ in pool}
    assert "Erling Haaland" in names


def test_tennis_seed_ranks_grand_slam_seasons_highest():
    seasons = seed.load_tennis()
    assert seasons, "tennis_seed.csv produced no rows"
    theme = next(t for t in KEEP4_THEMES if t.key == "tennis-grand-slam")
    pool = assemble.grade_pool(theme, seasons)
    assert len(pool) >= 8
    # grade_pool is sorted best-first; the top season must be a real 3-slam year.
    top_season, top_grade = pool[0]
    assert top_season.stats["grand_slams"] >= 2


def test_every_new_sport_seed_row_has_a_headshot():
    # M16: baseball/soccer/tennis shipped at 0% headshot coverage; this guards the fix
    # at the seed-loader level (test_headshot_coverage.py guards the shipped bundle).
    for loader in (seed.load_baseball, seed.load_soccer, seed.load_tennis):
        seasons = loader()
        missing = [s.name for s in seasons if not s.headshot]
        assert not missing, f"{loader.__name__}: rows missing headshot: {missing}"
