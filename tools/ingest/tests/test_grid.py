"""Tests for The Grid's generation + viability gate. Synthetic seasons only (no network)."""
from tools.ingest import grid
from tools.ingest.models import RawSeason


def _season(name, team, year, position="WR", sport="nfl"):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport=sport,
                     position=position, stats={"receiving_yards": 1000.0})


def _rich_pool():
    """3 teams x 3 decades, several players per cell -- fully viable by construction."""
    seasons = []
    teams = ["SF", "GB", "DAL"]
    decades = [1990, 2000, 2010]
    for team in teams:
        for decade in decades:
            for i in range(4):
                seasons.append(_season(f"{team}{decade}Player{i}", team, decade + i))
    return seasons


def test_generates_a_fully_viable_grid_from_a_rich_pool():
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08")
    assert puzzle is not None
    assert len(puzzle.row_teams) == 3
    assert len(puzzle.col_decades) == 3
    assert len(puzzle.cells) == 9
    for cell in puzzle.cells:
        assert len(cell.valid_answers) >= 1


def test_every_cell_answer_actually_matches_its_row_and_column():
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08")
    assert puzzle is not None
    for row_idx, team in enumerate(puzzle.row_teams):
        for col_idx, decade in enumerate(puzzle.col_decades):
            cell = puzzle.cell(row_idx, col_idx)
            for answer in cell.valid_answers:
                assert answer.team_abbr == team
                assert (answer.season_year // 10) * 10 == decade


def test_deterministic_for_same_sport_and_date():
    pool = _rich_pool()
    a = grid.generate_grid(pool, sport="nfl", date="2026-07-08")
    b = grid.generate_grid(pool, sport="nfl", date="2026-07-08")
    assert a == b


def test_different_dates_can_produce_different_grids():
    # More than 3 teams/decades so there's actual room for different picks across dates
    # (with exactly 3 of each, every combo is forced to use all of them).
    seasons = []
    teams = ["SF", "GB", "DAL", "NYG", "CHI"]
    decades = [1990, 2000, 2010, 2020]
    for team in teams:
        for decade in decades:
            for i in range(3):
                seasons.append(_season(f"{team}{decade}Player{i}", team, decade + i))
    results = {
        date: (r.row_teams, r.col_decades)
        for date in ["2026-07-08", "2026-07-09", "2026-07-10", "2026-07-11", "2026-07-12"]
        if (r := grid.generate_grid(seasons, sport="nfl", date=date)) is not None
    }
    assert len(set(results.values())) > 1, "expected at least some variation across dates"


def test_blank_team_abbr_is_never_picked_as_a_row_label():
    # Real live data surfaced this: some NBA rows have an unresolved/blank team_abbr, which
    # must never become a Grid row label ("" is missing data, not a real team).
    seasons = _rich_pool()
    for i in range(10):
        seasons.append(_season(f"Unresolved{i}", "", 2015 + i))
    for day in range(1, 21):
        puzzle = grid.generate_grid(seasons, sport="nfl", date=f"2026-07-{day:02d}")
        assert puzzle is not None
        assert "" not in puzzle.row_teams


def test_too_few_teams_returns_none():
    # Only 2 distinct teams -- can never fill 3 row slots.
    seasons = [_season("A", "SF", 1995), _season("B", "GB", 2005)]
    assert grid.generate_grid(seasons, sport="nfl", date="2026-07-08") is None


def test_sparse_pool_skips_infeasible_combos_until_a_viable_one_is_found():
    # 4 teams x 3 decades, but most cells are empty -- only one team/decade combo is
    # actually fully viable. The generator must find it via retries, not just fail.
    seasons = []
    dense_teams = ["SF", "GB", "DAL"]
    decades = [1990, 2000, 2010]
    for team in dense_teams:
        for decade in decades:
            seasons.append(_season(f"{team}{decade}", team, decade + 1))
    # A 4th team with almost no coverage -- combos including it should be skipped over.
    seasons.append(_season("SparseGuy", "NYG", 1995))
    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08", max_attempts=500)
    assert puzzle is not None
    for cell in puzzle.cells:
        assert len(cell.valid_answers) >= 1


def test_unbuildable_pool_returns_none_rather_than_a_broken_puzzle():
    # 4 teams x 3 decades, but so sparse that NO combo of 3 teams is fully viable.
    seasons = [
        _season("Only1", "SF", 1995),
        _season("Only2", "GB", 2005),
        _season("Only3", "DAL", 2015),
        _season("Only4", "NYG", 1995),
    ]
    assert grid.generate_grid(seasons, sport="nfl", date="2026-07-08", max_attempts=50) is None


def test_career_rows_and_other_sports_are_excluded_from_the_pool():
    seasons = _rich_pool()
    seasons.append(RawSeason(name="CareerGuy", team_abbr="SF", season_year=1999, sport="nfl",
                              position="WR", stats={}, career=True))
    seasons.append(_season("NBAGuy", "SF", 1995, position="G", sport="nba"))
    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08")
    assert puzzle is not None
    all_names = {a.name for cell in puzzle.cells for a in cell.valid_answers}
    assert "CareerGuy" not in all_names
    assert "NBAGuy" not in all_names


def test_rarity_stars_scale_inversely_with_pool_size():
    assert grid._rarity_stars(1) == 5
    assert grid._rarity_stars(3) == 4
    assert grid._rarity_stars(7) == 3
    assert grid._rarity_stars(14) == 2
    assert grid._rarity_stars(50) == 1


def test_to_content_shape_is_camel_case_and_matches_puzzle():
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08")
    assert puzzle is not None
    content = grid.to_content(puzzle)
    assert content["sport"] == puzzle.sport
    assert content["rowTeams"] == list(puzzle.row_teams)
    assert content["colDecades"] == list(puzzle.col_decades)
    assert len(content["cells"]) == 9
    for cell_json, cell in zip(content["cells"], puzzle.cells):
        assert cell_json["rarityStars"] == cell.rarity_stars
        assert cell_json["validAnswerNames"] == [a.name for a in cell.valid_answers]
        assert cell_json["validAnswerIds"] == [a.player_id for a in cell.valid_answers]


def test_puzzle_id_is_stable_and_namespaced_by_sport_and_date():
    assert grid.puzzle_id("nfl", "2026-07-08") == "grid-nfl-2026-07-08"
    assert grid.puzzle_id("nba", "2026-07-08") != grid.puzzle_id("nfl", "2026-07-08")
