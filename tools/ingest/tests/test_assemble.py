"""Assembly + validation tests using the curated NBA seed (no network)."""
from pathlib import Path

from tools.ingest import assemble, whoami_clues
from tools.ingest.models import RawSeason
from tools.ingest.providers import seed
from tools.ingest.themes import KEEP4_THEMES, Theme
from tools.ingest.validate import validate

DATA = Path(__file__).resolve().parents[1] / "data"
# Season-grain only: seed.load_nba() has no career-aggregate rows (those need
# career.build_career_rows, exercised separately in test_career.py), so a career-grain
# theme like nba-career-fantasy can never produce a puzzle from this pool alone.
NBA_THEMES = [t for t in KEEP4_THEMES if t.sport == "nba" and t.grain == "season"]


def _nba_seasons():
    """Seed rows with season totals derived, in the same order gather_seasons does it —
    nba_fantasy grades totals, so raw seed rows (averages only) would all grade 0."""
    from tools.ingest.main import derive_nba_totals
    seasons = seed.load_nba()
    derive_nba_totals(seasons)
    return seasons


def test_keep4_rows_are_valid_and_clustered():
    seasons = _nba_seasons()
    produced = 0
    for theme in NBA_THEMES:
        rows = assemble.build_keep4_rows(theme, seasons)
        assert rows, f"{theme.key} produced no puzzles"
        for row in rows:
            validate(row)  # 8 players, unambiguous boundary, shape OK
            grades = sorted((p["grade"] for p in row.content["players"]), reverse=True)
            # clustered: full spread across 8 cards stays tight RELATIVE to the window's
            # magnitude (grades are season totals ~5,000 now, so an absolute bound like
            # the old `< 45` is meaningless; seed pool worst case measures ~29%).
            assert grades[0] - grades[-1] < 0.35 * grades[0]
            produced += 1
    assert produced >= len(NBA_THEMES)


def test_keep4_top4_matches_grade_ranking():
    seasons = _nba_seasons()
    theme = next(t for t in NBA_THEMES if t.key == "nba-scorers")
    row = assemble.build_keep4_rows(theme, seasons)[0]
    players = row.content["players"]
    top4 = {p["id"] for p in sorted(players, key=lambda p: -p["grade"])[:4]}
    # The four highest grades are exactly the intended Keep pile.
    assert len(top4) == 4


def test_variants_have_unique_ids():
    seasons = _nba_seasons()
    ids = []
    for theme in NBA_THEMES:
        ids += [r.id for r in assemble.build_keep4_rows(theme, seasons)]
    assert len(ids) == len(set(ids))


def test_catalog_rows_dedupe_and_shape():
    from tools.ingest.main import catalog_rows
    seasons = _nba_seasons()
    rows = catalog_rows(seasons + seasons)   # duplicates collapse by id
    ids = [r["id"] for r in rows]
    assert len(ids) == len(set(ids))
    sample = rows[0]
    assert {"id", "sport", "name", "team_abbr", "season_year", "position", "stats"} <= sample.keys()
    assert isinstance(sample["stats"], dict)


def test_keep4_rows_bake_grain_field():
    seasons = _nba_seasons()
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
        assert row.content["answer"]["canonical"]
        assert row.content["difficulty"] in {"easy", "medium", "hard"}


def test_whoami_clue_sets_vary_by_subject_and_by_seed():
    """The clue set used to be the same six kinds in the same order for every puzzle in the
    game (era → position → teams → statLine → fact → jersey). It's now drawn per subject and
    per serve date, which is the whole point of the change — so pin that it actually varies.
    """
    entries = assemble.load_whoami_entries(DATA / "whoami_facts.json")

    def dimensions(entry, seed=""):
        row = assemble.build_whoami_row(entry, seed=seed)
        return tuple(c["dimension"] for c in row.content["clues"])

    across_subjects = {dimensions(e) for e in entries}
    assert len(across_subjects) > len(entries) // 2, "most subjects share one clue shape"

    one = entries[0]
    across_seeds = {dimensions(one, seed=f"2026-09-{d:02d}") for d in range(1, 15)}
    assert len(across_seeds) > 1, "the same subject draws identically on every date"


def test_whoami_clues_open_broad_and_close_specific():
    """Randomizing the *set* must not randomize the difficulty curve: whichever dimensions get
    drawn, clue 1 has to give away less than clue 6, or the puzzle is solvable on sight."""
    for entry in assemble.load_whoami_entries(DATA / "whoami_facts.json"):
        for seed in ("", "2026-08-06", "2027-01-01"):
            clues = whoami_clues.select_clues(entry, seed=seed)
            assert clues[0].reveal < clues[-1].reveal, f"{entry.canonical} @ {seed}"


def test_photo_less_lower_division_soccer_row_never_becomes_a_puzzle_card():
    # `--allow-missing-photos` keeps ger.2 rows Wikipedia has no photo for, because a Draft &
    # Spin roster row renders an initial-avatar circle. A Keep4 card IS the photo, so the same
    # row must not reach the bundle — otherwise test_headshot_coverage trips on every refresh.
    theme = Theme(key="soccer-fw", title="Soccer FW", sport="soccer",
                  scale="soccer_attacker_fantasy", positions=["FW"], min_stats={},
                  columns=[], pool_cap=50, grain="season")
    photoless = RawSeason(name="Lower Division Guy", team_abbr="SCP", season_year=2025,
                          sport="soccer", position="FW", stats={"goals": 20.0},
                          source="espn", headshot="")
    withphoto = RawSeason(name="Top Flight Guy", team_abbr="BAY", season_year=2025,
                          sport="soccer", position="FW", stats={"goals": 20.0},
                          source="espn", headshot="https://example/photo.jpg")
    pool = assemble.grade_pool(theme, [photoless, withphoto])
    names = {s.name for s, _ in pool}
    assert names == {"Top Flight Guy"}


# ── One human per board ──────────────────────────────────────────────────────────

def test_same_person_matches_a_display_name_and_its_formal_extension():
    from tools.ingest.assemble import _same_person
    assert _same_person("Cristiano Ronaldo", "Cristiano Ronaldo dos Santos Aveiro")
    assert _same_person("Cristiano Ronaldo dos Santos Aveiro", "Cristiano Ronaldo")
    assert _same_person("Kylian Mbappé", "kylian mbappé")


def test_same_person_does_not_fire_on_a_shared_surname_or_first_name():
    from tools.ingest.assemble import _same_person
    # Different players who merely share a name part must stay distinct.
    assert not _same_person("Gary Neville", "Phil Neville")
    assert not _same_person("Eden Hazard", "Thorgan Hazard")
    assert not _same_person("Ronaldo", "Ronaldo Luis Nazario")   # one-word side is too weak
    assert not _same_person("Diego Costa", "Diego Forlan")


def test_a_window_containing_one_player_twice_is_rejected():
    """Four live boards asked players to rank Cristiano Ronaldo against himself, because the
    catalog carries him under both a display and a formal name with different ids."""
    from tools.ingest.assemble import _windows
    from tools.ingest.models import RawSeason

    def season(name, year):
        return RawSeason(name=name, team_abbr="RMA", season_year=year, sport="soccer",
                         position="FW", stats={"goals": 30.0}, headshot="h")

    ranked = [(season(f"Player {i}", 2010 + i), 100.0 - i) for i in range(8)]
    assert _windows(ranked, 1), "sanity: a clean window builds"

    # Same eight, but two cards are one human.
    ranked[2] = (season("Cristiano Ronaldo", 2013), ranked[2][1])
    ranked[5] = (season("Cristiano Ronaldo dos Santos Aveiro", 2016), ranked[5][1])
    assert _windows(ranked, 1) == [], "a board must never contain the same player twice"
