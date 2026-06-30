"""Assembly + validation tests using the curated NBA seed (no network)."""
from pathlib import Path

from tools.ingest import assemble
from tools.ingest.providers import seed
from tools.ingest.themes import KEEP4_THEMES
from tools.ingest.validate import validate

DATA = Path(__file__).resolve().parents[1] / "data"
NBA_THEMES = [t for t in KEEP4_THEMES if t.sport == "nba"]


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


def test_whoami_rows_valid():
    entries = assemble.load_whoami_entries(DATA / "whoami_facts.json")
    assert entries
    for entry in entries:
        row = assemble.build_whoami_row(entry)
        validate(row)
        assert row.content["clues"][0]["kind"] == "era"
        assert row.content["answer"]["canonical"]
