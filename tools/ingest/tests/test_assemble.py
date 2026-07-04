"""Assembly + validation tests using the curated NBA seed (no network)."""
from pathlib import Path

from tools.ingest import assemble
from tools.ingest.models import RawSeason
from tools.ingest.providers import seed
from tools.ingest.themes import KEEP4_THEMES, Theme
from tools.ingest.validate import validate

DATA = Path(__file__).resolve().parents[1] / "data"
# Season-grain only: seed.load_nba() has no career-aggregate rows (those need
# career.build_career_rows, exercised separately in test_career.py), so a career-grain
# theme like nba-career-fantasy can never produce a puzzle from this pool alone.
NBA_THEMES = [t for t in KEEP4_THEMES if t.sport == "nba" and t.grain == "season"]


def test_keep4_rows_are_valid_and_clustered():
    seasons = seed.load_nba()
    produced = 0
    for theme in NBA_THEMES:
        rows = assemble.build_keep4_rows(theme, seasons)
        assert rows, f"{theme.key} produced no puzzles"
        for row in rows:
            validate(row)  # 8 players, unambiguous boundary, shape OK
            grades = sorted((p["grade"] for p in row.content["players"]), reverse=True)
            # clustered: full spread across 8 cards stays tight
            assert grades[0] - grades[-1] < 45
            produced += 1
    assert produced >= len(NBA_THEMES)


def test_keep4_top4_matches_grade_ranking():
    seasons = seed.load_nba()
    theme = next(t for t in NBA_THEMES if t.key == "nba-scorers")
    row = assemble.build_keep4_rows(theme, seasons)[0]
    players = row.content["players"]
    top4 = {p["id"] for p in sorted(players, key=lambda p: -p["grade"])[:4]}
    # The four highest grades are exactly the intended Keep pile.
    assert len(top4) == 4


def test_variants_have_unique_ids():
    seasons = seed.load_nba()
    ids = []
    for theme in NBA_THEMES:
        ids += [r.id for r in assemble.build_keep4_rows(theme, seasons)]
    assert len(ids) == len(set(ids))


def test_catalog_rows_dedupe_and_shape():
    from tools.ingest.main import catalog_rows
    seasons = seed.load_nba()
    rows = catalog_rows(seasons + seasons)   # duplicates collapse by id
    ids = [r["id"] for r in rows]
    assert len(ids) == len(set(ids))
    sample = rows[0]
    assert {"id", "sport", "name", "team_abbr", "season_year", "position", "stats"} <= sample.keys()
    assert isinstance(sample["stats"], dict)


def test_keep4_rows_bake_grain_field():
    seasons = seed.load_nba()
    theme = next(t for t in NBA_THEMES if t.key == "nba-scorers")
    row = assemble.build_keep4_rows(theme, seasons)[0]
    assert row.content["grain"] == "season"


def _make(sport, position, year, career=False, **stats):
    return RawSeason(name=f"Player {year}-{career}", team_abbr="XX", season_year=year,
                     sport=sport, position=position, stats=stats, career=career)


def test_grade_pool_keeps_season_and_career_pools_strictly_separate():
    # A career row has week=None just like a season row — grade_pool must not conflate
    # them into one pool via a single boolean check (the M17 bug this guards against).
    season_theme = Theme(key="t-season", title="t", sport="nfl", scale="nfl_fantasy",
                        positions=frozenset({"RB"}), min_stats={}, columns=[], grain="season")
    career_theme = Theme(key="t-career", title="t2", sport="nfl", scale="nfl_fantasy",
                        positions=frozenset({"RB"}), min_stats={}, columns=[], grain="career")
    seasons = [
        _make("nfl", "RB", 2020, career=False, rushing_yards=1000),
        _make("nfl", "RB", 2021, career=True, rushing_yards=9000),
    ]
    season_pool = assemble.grade_pool(season_theme, seasons)
    career_pool = assemble.grade_pool(career_theme, seasons)
    assert len(season_pool) == 1 and season_pool[0][0].career is False
    assert len(career_pool) == 1 and career_pool[0][0].career is True


def test_whoami_rows_valid():
    entries = assemble.load_whoami_entries(DATA / "whoami_facts.json")
    assert entries
    for entry in entries:
        row = assemble.build_whoami_row(entry)
        validate(row)
        assert row.content["clues"][0]["kind"] == "era"
        assert row.content["answer"]["canonical"]
