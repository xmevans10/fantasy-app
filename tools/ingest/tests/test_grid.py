"""Tests for The Grid's generation + viability gate. Synthetic seasons only (no network).

The board became symmetric on 2026-07-27 (rows and columns are both `GridAxis` lists, any kind
on either dimension) after being hardcoded teams x decades since it shipped. Tests that care
about a specific board SHAPE pin an archetype via `archetypes=`; the rest assert shape-agnostic
guarantees, because with the real rotation in play a given (sport, date) may legitimately mint a
teams x stats or teams x teams board instead.
"""
import pytest

from tools.ingest import grid, grid_axes
from tools.ingest.models import RawSeason

# Pinned single-archetype rotations, so a test about (say) roster extras isn't also implicitly
# testing which shape the weighted rotation happened to pick that day.
TEAMS_X_DECADES = (grid.Archetype("teams-x-decades", "team", "decade", weight=1),)
TEAMS_X_TEAMS = (grid.Archetype("teams-x-teams", "team_career", "team_career", weight=1),)
TEAMS_X_STATS = (grid.Archetype("teams-x-stats", "team", "stat", weight=1),)


def _season(name, team, year, position="WR", sport="nfl", stats=None):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport=sport,
                     position=position,
                     stats={"receiving_yards": 1000.0} if stats is None else stats)


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
    assert len(puzzle.rows) == 3
    assert len(puzzle.cols) == 3
    assert len(puzzle.cells) == 9
    for cell in puzzle.cells:
        assert len(cell.valid_answers) >= 1


def test_every_cell_answer_actually_matches_its_row_and_column():
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_DECADES)
    assert puzzle is not None
    for row_idx, row in enumerate(puzzle.rows):
        for col_idx, col in enumerate(puzzle.cols):
            cell = puzzle.cell(row_idx, col_idx)
            for answer in cell.valid_answers:
                assert answer.team_abbr == row.label
                assert (answer.season_year // 10) * 10 == int(col.label.rstrip("s"))


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
        date: grid.combo_key(r.rows, r.cols)
        for date in ["2026-07-08", "2026-07-09", "2026-07-10", "2026-07-11", "2026-07-12"]
        if (r := grid.generate_grid(seasons, sport="nfl", date=date)) is not None
    }
    assert len(set(results.values())) > 1, "expected at least some variation across dates"


def test_blank_team_abbr_is_never_picked_as_an_axis_label():
    # Real live data surfaced this: some NBA rows have an unresolved/blank team_abbr, which
    # must never become a Grid axis label ("" is missing data, not a real team).
    seasons = _rich_pool()
    for i in range(10):
        seasons.append(_season(f"Unresolved{i}", "", 2015 + i))
    for day in range(1, 21):
        puzzle = grid.generate_grid(seasons, sport="nfl", date=f"2026-07-{day:02d}")
        assert puzzle is not None
        labels = {a.label for a in puzzle.rows} | {a.label for a in puzzle.cols}
        assert "" not in labels


def test_too_few_teams_returns_none():
    # Only 2 distinct teams -- can never fill 3 axis slots.
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
    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08", max_attempts=500,
                                archetypes=TEAMS_X_DECADES)
    assert puzzle is not None
    for cell in puzzle.cells:
        assert len(cell.valid_answers) >= 1


def test_unbuildable_pool_returns_none_rather_than_a_broken_puzzle():
    # 4 teams x 3 decades, but so sparse that NO combo of 3 axes is fully viable.
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


def test_puzzle_id_is_stable_and_namespaced_by_sport_and_date():
    assert grid.puzzle_id("nfl", "2026-07-08") == "grid-nfl-2026-07-08"
    assert grid.puzzle_id("nba", "2026-07-08") != grid.puzzle_id("nfl", "2026-07-08")


# MARK: grain semantics -- the rule that makes team x team possible and team x decade correct


def test_team_x_team_matches_a_player_who_played_for_both_in_different_seasons():
    """The single most recognisable Immaculate Grid cell, and the one the old teams x decades
    shape could not express. It only works because team axes go career-grain here: a season row
    has exactly one team, so two season-grain team axes could never be co-satisfied."""
    # Six clubs, because rows and columns must be disjoint (see
    # `test_the_same_axis_never_appears_on_both_a_row_and_a_column`) -- a team x team board is
    # only possible for a sport with at least six franchises, which every real one has.
    clubs = ["SF", "GB", "DAL", "NYG", "CHI", "MIA"]
    seasons = [_season(f"{team}Only{i}", team, 2000 + i) for team in clubs for i in range(3)]
    # A journeyman for every ordered pair, so whichever disjoint 3x3 split is drawn is viable.
    for a in clubs:
        for b in clubs:
            if a != b:
                seasons += [_season(f"Journey {a}{b}", a, 2001),
                            _season(f"Journey {a}{b}", b, 2005)]

    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_TEAMS, max_attempts=500)
    assert puzzle is not None
    # Every off-diagonal cell pairs two different clubs and must be filled by the journeyman
    # who played for both -- never by a single-club player.
    for r, row in enumerate(puzzle.rows):
        for c, col in enumerate(puzzle.cols):
            names = {a.name for a in puzzle.cell(r, c).valid_answers}
            assert names, f"{row.label} x {col.label} should have an answer"
            for name in names:
                teams_played = {s.team_abbr for s in seasons if s.name == name}
                assert {row.label, col.label} <= teams_played


def test_season_grain_axes_must_be_satisfied_by_the_same_season():
    """team + decade is "played for them IN that decade", not "played for them, and separately
    played somewhere in that decade" -- Immaculate Grid's own team+season-stat rule."""
    seasons = _rich_pool()
    # Played for SF only in 2015, and for GB only in 1995. Must NOT satisfy SF x 1990s.
    seasons.append(_season("Split Career", "SF", 2015))
    seasons.append(_season("Split Career", "GB", 1995))
    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_DECADES)
    assert puzzle is not None
    for r, row in enumerate(puzzle.rows):
        for c, col in enumerate(puzzle.cols):
            if row.label != "SF" or col.label != "1990s":
                continue
            assert "Split Career" not in {a.name for a in puzzle.cell(r, c).valid_answers}


def _soccer(name, team, year, league, position="FW"):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport="soccer",
                     position=position, stats={"goals": 12.0, "appearances": 30.0},
                     meta={"league": league})


def test_soccer_team_axes_never_merge_two_clubs_sharing_a_code():
    """Measured live 2026-07-27: 51 of 954 soccer abbreviations carry rows from two genuinely
    different clubs. MCI is Manchester City (England, 288 rows) AND Melbourne City (Australia,
    132). Unscoped, one "MCI" axis accepted either club's players as a correct answer."""
    seasons = []
    for i in range(6):
        seasons.append(_soccer(f"City England {i}", "MCI", 2015 + i, "England"))
        seasons.append(_soccer(f"City Australia {i}", "MCI", 2015 + i, "Australia"))
        seasons.append(_soccer(f"Toro Italy {i}", "TOR", 2015 + i, "Italy"))
        seasons.append(_soccer(f"Toronto MLS {i}", "TOR", 2015 + i, "USA (MLS)"))
        seasons.append(_soccer(f"Gala Turkey {i}", "GAL", 2015 + i, "Turkey"))
        seasons.append(_soccer(f"Galaxy MLS {i}", "GAL", 2015 + i, "USA (MLS)"))

    by_league = {(s.team_abbr, s.meta["league"]): set() for s in seasons}
    for s in seasons:
        by_league[(s.team_abbr, s.meta["league"])].add(s.name)

    found = False
    for day in range(1, 29):
        puzzle = grid.generate_grid(seasons, sport="soccer", date=f"2026-07-{day:02d}")
        if puzzle is None:
            continue
        for r, row in enumerate(puzzle.rows):
            for c, col in enumerate(puzzle.cols):
                for axis in (row, col):
                    if axis.kind != "team":
                        continue
                    found = True
                    assert axis.league, f"soccer team axis {axis.key} carries no league"
                    allowed = by_league[(axis.abbr, axis.league)]
                    for answer in puzzle.cell(r, c).valid_answers:
                        assert answer.name in allowed, \
                            f"{answer.name!r} is not a {axis.abbr}/{axis.league} player"
    assert found, "expected at least one soccer team axis across a month of boards"


def test_soccer_team_axes_render_a_league_qualified_label():
    """Scoping alone fixes the answer set but leaves two axes both reading "MCI" — correct
    underneath, indistinguishable on screen. The nation code makes the board self-describing."""
    assert grid_axes.team_axis("MCI", league="England").label == "MCI-ENG"
    assert grid_axes.team_axis("MCI", league="Australia").label == "MCI-AUS"
    assert grid_axes.team_axis("TOR", league="Italy").label == "TOR-ITA"
    assert grid_axes.team_axis("GAL", league="Turkey").label == "GAL-TUR"
    assert grid_axes.team_axis("TOR", league="USA (MLS)").label == "TOR-USA"
    # Codes come from the committed competition table, not a second hand-written map.
    assert grid_axes.league_code("England") == "ENG"
    # An unknown label still yields something usable rather than blowing up.
    assert grid_axes.league_code("Atlantis") == "ATL"
    assert grid_axes.league_code("") == ""


def test_qualified_label_keeps_the_raw_abbr_for_crest_lookup():
    """The label is for humans; `abbr`/`league` are what the client keys colors and crests on.
    Conflating them would send "MCI-ENG" to a `teams` table that only knows "MCI"."""
    axis = grid_axes.team_axis("MCI", league="England")
    assert axis.label == "MCI-ENG"
    assert axis.abbr == "MCI"
    assert axis.league == "England"


def test_us_sport_team_axes_stay_unscoped():
    """NFL/NBA/MLB codes are unique on their own, so nothing changes for them — no league filter,
    and the key stays the bare `team:ABBR` that `grid_history` has always stored."""
    axis = grid_axes.team_axis("KC")
    assert axis.key == "team:KC"
    assert axis.league == ""
    assert len(axis.filters) == 1


def test_soccer_rows_without_a_league_are_not_offered_as_axes():
    """A blank league under a league-scoped sport would produce an axis with no league filter —
    i.e. exactly the merged-club behaviour this scoping exists to prevent — so those rows are
    dropped from axis selection rather than silently becoming a catch-all."""
    seasons = [_soccer(f"Known {i}", "MCI", 2015 + i, "England") for i in range(6)]
    seasons += [_soccer(f"Unknown {i}", "XXX", 2015 + i, "") for i in range(6)]
    keys = grid._team_keys(seasons, league_scoped=True)
    assert ("MCI", "England") in keys
    assert not any(abbr == "XXX" for abbr, _ in keys)


def test_tennis_never_gets_a_team_x_team_board():
    """`team_abbr` is the player's COUNTRY in tennis and can't change, so "played for both USA
    and CRO" is unviable for every player alive -- the archetype must be refused outright rather
    than burning all 200 attempts."""
    seasons = [_season(f"P{i}", country, 2000 + i, position="Player", sport="tennis",
                       stats={"titles": 5.0})
               for country in ["USA", "CRO", "NED", "ESP"] for i in range(4)]
    assert grid.generate_grid(seasons, sport="tennis", date="2026-07-08",
                              archetypes=TEAMS_X_TEAMS, max_attempts=50) is None
    assert "tennis" not in grid_axes.TEAM_MOBILE_SPORTS


def test_the_same_axis_never_appears_on_both_a_row_and_a_column():
    """teams x teams draws both dimensions from one pool, so without an explicit guard a board
    could ask "SF and SF" -- a cell every SF player trivially satisfies."""
    seasons = []
    for team in ["SF", "GB", "DAL", "NYG", "CHI", "MIA"]:
        for other in ["SF", "GB", "DAL", "NYG", "CHI", "MIA"]:
            if team != other:
                seasons.append(_season(f"{team}-{other}", team, 2001))
                seasons.append(_season(f"{team}-{other}", other, 2005))
    for day in range(1, 15):
        puzzle = grid.generate_grid(seasons, sport="nfl", date=f"2026-07-{day:02d}",
                                    archetypes=TEAMS_X_TEAMS, max_attempts=500)
        if puzzle is None:
            continue
        assert not ({a.key for a in puzzle.rows} & {a.key for a in puzzle.cols})


# MARK: stat axes


def test_stat_axis_only_accepts_seasons_clearing_the_threshold():
    # Enough distinct stat keys populated that at least three receiving axes are viable --
    # a teams x stats board needs three columns, so a pool carrying one stat can never fill it.
    big = {"receiving_yards": 1500.0, "receptions": 95.0, "receiving_tds": 14.0}
    small = {"receiving_yards": 200.0, "receptions": 20.0, "receiving_tds": 1.0}
    seasons = []
    for team in ["SF", "GB", "DAL"]:
        for i in range(4):
            seasons.append(_season(f"{team}Big{i}", team, 2000 + i, stats=big))
            seasons.append(_season(f"{team}Small{i}", team, 2000 + i, stats=small))
    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_STATS, max_attempts=500)
    assert puzzle is not None
    for c, col in enumerate(puzzle.cols):
        if col.label != "1,400+ Rec Yds":
            continue
        for r in range(3):
            for answer in puzzle.cell(r, c).valid_answers:
                assert "Small" not in answer.name


def test_rate_stat_axes_carry_a_volume_gate():
    """A .400 average over three plate appearances is not "a .300 hitter". Every rate-stat axis
    must pair its threshold with a playing-time filter, or the cell fills with call-ups."""
    rate_stats = {"avg", "ops", "era", "whip", "fg_pct", "fg3_pct", "ts_pct",
                  "ppg", "rpg", "apg", "bpg", "spg"}
    for sport in ["nfl", "nba", "baseball", "soccer", "tennis"]:
        for axis in grid_axes.stat_axes(sport):
            stat = axis.key.split(":")[1]
            if stat in rate_stats:
                assert len(axis.filters) > 1, f"{sport} axis {axis.label!r} has no volume gate"


def test_a_board_never_shows_another_sports_axis():
    """No NFL board may ever offer "Midfielders" or "30+ Stolen Bases".

    The catalogs are keyed by sport so this holds by construction today, but it's the kind of
    thing a later refactor (a shared "all stats" pool, a merged position table) would quietly
    break, and the result would be nonsense on the board rather than a crash. Asserted at the
    generation level, not just against the catalog dicts, so it also covers `_axis_pool`'s
    dispatch and the `mixed` dimension's concatenation.
    """
    stats_by_sport = {s: {a.label for a in grid_axes.stat_axes(s)}
                      for s in ["nfl", "nba", "baseball", "soccer", "tennis"]}
    positions_by_sport = {s: {a.label for a in grid_axes.position_axes(s)}
                          for s in ["nfl", "nba", "baseball", "soccer", "tennis"]}

    # A pool rich enough that the rotation can actually reach every archetype.
    stats = {"receiving_yards": 1500.0, "receptions": 95.0, "receiving_tds": 14.0,
             "rushing_yards": 1600.0, "rushing_tds": 12.0, "passing_yards": 4200.0,
             "passing_tds": 35.0}
    seasons = []
    for team in ["SF", "GB", "DAL", "NYG", "CHI", "MIA"]:
        for decade in [1990, 2000, 2010]:
            for i, pos in enumerate(["QB", "RB", "WR", "TE"]):
                seasons.append(_season(f"{team}{decade}{pos}", team, decade + i,
                                       position=pos, stats=stats))
        seasons.append(_season(f"{team}Journey", team, 2005, stats=stats))
        seasons.append(_season(f"{team}Journey", "SF" if team != "SF" else "GB", 2009,
                               stats=stats))

    seen_archetypes = set()
    for day in range(1, 29):
        puzzle = grid.generate_grid(seasons, sport="nfl", date=f"2026-07-{day:02d}")
        if puzzle is None:
            continue
        seen_archetypes.add(puzzle.archetype)
        for axis in puzzle.rows + puzzle.cols:
            if axis.kind == "stat":
                assert axis.label in stats_by_sport["nfl"], \
                    f"{axis.label!r} is not an NFL stat"
                for other, labels in stats_by_sport.items():
                    if other != "nfl":
                        assert axis.label not in labels - stats_by_sport["nfl"], \
                            f"{axis.label!r} leaked in from {other}"
            if axis.kind == "position":
                assert axis.label in positions_by_sport["nfl"], \
                    f"{axis.label!r} is not an NFL position"
    # Only meaningful if the mixed archetype (the one that concatenates pools) actually ran.
    assert "teams-x-mixed" in seen_archetypes


def test_every_declared_stat_axis_is_reachable_for_its_sport():
    """Guards against a typo'd stat key silently producing an axis that matches nothing and just
    burns generation attempts forever."""
    for sport in ["nfl", "nba", "baseball", "soccer", "tennis"]:
        for axis in grid_axes.stat_axes(sport):
            assert axis.kind == "stat"
            assert axis.label and axis.key
            assert axis.filters


# MARK: archetype rotation


def test_rotation_produces_more_than_one_board_shape_over_time():
    """The whole point of the change: before this, every board ever minted was teams x decades."""
    seasons = []
    for team in ["SF", "GB", "DAL", "NYG", "CHI", "MIA"]:
        for decade in [1990, 2000, 2010]:
            for i in range(4):
                seasons.append(_season(f"{team}{decade}P{i}", team, decade + i,
                                       position=["QB", "RB", "WR", "TE"][i],
                                       stats={"receiving_yards": 1200.0,
                                             "rushing_yards": 1100.0,
                                             "passing_yards": 4200.0,
                                             "passing_tds": 35.0,
                                             "rushing_tds": 12.0,
                                             "receiving_tds": 12.0,
                                             "receptions": 90.0}))
        # Journeymen so teams x teams is viable too.
        seasons.append(_season(f"{team}Journey", team, 2005))
        seasons.append(_season(f"{team}Journey", "SF" if team != "SF" else "GB", 2009))
    shapes = set()
    for day in range(1, 29):
        puzzle = grid.generate_grid(seasons, sport="nfl", date=f"2026-07-{day:02d}")
        if puzzle is not None:
            shapes.add(puzzle.archetype)
    assert len(shapes) > 1, f"expected shape variety across a month, only saw {shapes}"


def test_every_cell_is_anchored_to_a_team():
    """A cell is only specific because a team narrows it. Boards with no team dimension at all
    ("Midfielders x 2020s", "2010s x 10+ Assists") shipped in a first pass and came back rarity 1
    across all nine cells on live data — thousands of valid answers each, because the question is
    really "name any midfielder". See ARCHETYPES' comment.

    Stated per *cell*, not per dimension: a heterogeneous dimension can't be relied on for the
    anchor (any one of its axes may be a non-team), so it only counts when the dimension facing
    it is all-team."""
    for archetype in grid.ARCHETYPES:
        dims = {archetype.rows, archetype.cols}
        if dims & grid.HETEROGENEOUS_DIMENSIONS:
            # The varying side can't anchor, so the other side must be wholly team.
            other = archetype.cols if archetype.rows in grid.HETEROGENEOUS_DIMENSIONS else archetype.rows
            assert other in grid.TEAM_DIMENSIONS, \
                f"{archetype.key} pairs a heterogeneous dimension with a non-team one"
        else:
            assert grid.TEAM_DIMENSIONS & dims, f"{archetype.key} has no team dimension"


def test_mixed_any_only_faces_a_team_dimension():
    """`mixed_any` may itself contain a team axis, which makes it tempting to treat as
    self-anchoring — it isn't. Two `mixed_any` dimensions could put a stat opposite a decade and
    produce exactly the rarity-1 "name any player who ever rushed for 1,000" cell the anchoring
    rule exists to prevent."""
    for archetype in grid.ARCHETYPES:
        for dim, other in ((archetype.rows, archetype.cols), (archetype.cols, archetype.rows)):
            if dim == "mixed_any":
                assert other in grid.TEAM_DIMENSIONS, \
                    f"{archetype.key}: mixed_any must face an all-team dimension, got {other!r}"


def test_archetype_is_skipped_when_the_sport_cannot_offer_three_axes():
    """Baseball has exactly two positions (H/P), so a positions dimension can never fill three
    slots -- the archetype must be passed over, not attempted 200 times."""
    assert len(grid_axes.position_axes("baseball")) < 3
    seasons = [_season(f"P{i}", team, 2000 + i, position="H", sport="baseball",
                       stats={"home_runs": 35.0})
               for team in ["NYY", "BOS", "LAD"] for i in range(4)]
    positions_x_decades = (grid.Archetype("positions-x-decades", "position", "decade", weight=1),)
    assert grid.generate_grid(seasons, sport="baseball", date="2026-07-08",
                              archetypes=positions_x_decades, max_attempts=20) is None


# MARK: content shape (v2 symmetric axes + v1 back-compat)


def test_to_content_emits_symmetric_axes_and_a_version():
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08")
    assert puzzle is not None
    content = grid.to_content(puzzle)
    assert content["sport"] == puzzle.sport
    assert content["version"] == grid.CONTENT_VERSION == 2
    assert content["archetype"] == puzzle.archetype
    assert [a["label"] for a in content["rows"]] == [a.label for a in puzzle.rows]
    assert [a["label"] for a in content["cols"]] == [a.label for a in puzzle.cols]
    for axis_json, axis in zip(content["rows"] + content["cols"], puzzle.rows + puzzle.cols):
        assert axis_json["kind"] == axis.kind
        assert axis_json["grain"] == axis.grain
        assert axis_json["key"] == axis.key
    assert len(content["cells"]) == 9
    for cell_json, cell in zip(content["cells"], puzzle.cells):
        assert cell_json["rarityStars"] == cell.rarity_stars
        assert cell_json["validAnswerNames"] == [a.name for a in cell.valid_answers]
        assert cell_json["validAnswerIds"] == [a.player_id for a in cell.valid_answers]


def test_teams_x_decades_boards_still_emit_the_legacy_keys():
    """A live board is immutable for its day, so a player can be mid-grid when a new build ships.
    Boards that ARE the classic shape keep emitting `rowTeams`/`colDecades` so a pre-v2 client
    renders them normally through the rollout."""
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_DECADES)
    assert puzzle is not None
    content = grid.to_content(puzzle)
    assert content["rowTeams"] == [a.label for a in puzzle.rows]
    assert content["colDecades"] == [int(a.label.rstrip("s")) for a in puzzle.cols]
    assert all(isinstance(d, int) for d in content["colDecades"])


def test_non_classic_boards_omit_the_legacy_keys_rather_than_faking_them():
    """There is no honest v1 rendering of a teams x teams board, so an old client must see no
    board at all rather than a wrong one."""
    clubs = ["SF", "GB", "DAL", "NYG", "CHI", "MIA"]
    seasons = []
    for a in clubs:
        for b in clubs:
            if a != b:
                seasons += [_season(f"{a}-{b}", a, 2001), _season(f"{a}-{b}", b, 2005)]
    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_TEAMS, max_attempts=500)
    assert puzzle is not None
    content = grid.to_content(puzzle)
    assert "rowTeams" not in content
    assert "colDecades" not in content


# MARK: recently-served rejection (grid_history trailing window)


def test_recently_served_combo_is_rejected_in_favor_of_the_next_viable_one():
    # 5 teams x 4 decades so an alternative combo exists once the first is vetoed.
    seasons = []
    for team in ["SF", "GB", "DAL", "NYG", "CHI"]:
        for decade in [1990, 2000, 2010, 2020]:
            for i in range(3):
                seasons.append(_season(f"{team}{decade}Player{i}", team, decade + i))
    first = grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                               archetypes=TEAMS_X_DECADES)
    assert first is not None
    served = {grid.combo_key(first.rows, first.cols)}
    second = grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_DECADES, recently_served=served)
    assert second is not None
    assert grid.combo_key(second.rows, second.cols) not in served


def test_recently_served_rejection_is_order_independent():
    first = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                               archetypes=TEAMS_X_DECADES)
    assert first is not None
    # Store the key with axes listed in a different order than the puzzle's own -- combo_key
    # must canonicalize (sorted) so a shuffled repeat is still caught.
    shuffled = tuple(reversed(first.rows))
    assert grid.combo_key(shuffled, first.cols) == grid.combo_key(first.rows, first.cols)


def test_fully_served_space_returns_none_rather_than_repeating():
    # _rich_pool has exactly 3 teams x 3 decades -- only one possible teams x decades combo.
    # Once it's in the trailing window there's nothing novel left to mint in that shape.
    only = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                              archetypes=TEAMS_X_DECADES)
    assert only is not None
    served = {grid.combo_key(only.rows, only.cols)}
    assert grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-09",
                              archetypes=TEAMS_X_DECADES,
                              max_attempts=50, recently_served=served) is None


# MARK: roster extras (nfl_rosters -> extra_members) -- validity widens, stars/viability don't

from tools.ingest.providers.nfl_rosters import RosterMember


def test_extra_members_widen_cell_validity():
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_DECADES,
                                extra_members=[RosterMember("Roster Guy", team, decade + 1)
                                               for team in ["SF", "GB", "DAL"]
                                               for decade in [1990, 2000, 2010]])
    assert puzzle is not None
    for cell in puzzle.cells:
        assert "Roster Guy" in {a.name for a in cell.valid_answers}


def test_extra_members_do_not_change_rarity_stars():
    base = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                              archetypes=TEAMS_X_DECADES)
    extras = [RosterMember(f"Extra{i}", team, decade)
              for i in range(40)
              for team in ["SF", "GB", "DAL"]
              for decade in [1990, 2000, 2010]]
    widened = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                                 archetypes=TEAMS_X_DECADES, extra_members=extras)
    assert base is not None and widened is not None
    assert [c.rarity_stars for c in base.cells] == [c.rarity_stars for c in widened.cells]


def test_extra_members_never_create_viability():
    # A pool missing one decade entirely can't be rescued by roster-only members there.
    seasons = [_season(f"P{i}", "SF", 1990 + i) for i in range(4)]
    extras = [RosterMember(f"R{i}", "SF", 2000 + i) for i in range(4)]
    assert grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                              max_attempts=50, extra_members=extras) is None


def test_extra_member_duplicating_a_graded_player_is_not_double_counted():
    extras = [RosterMember("SF1990Player0", "SF", 1993)]
    puzzle = grid.generate_grid(_rich_pool(), sport="nfl", date="2026-07-08",
                                archetypes=TEAMS_X_DECADES, extra_members=extras)
    assert puzzle is not None
    for cell in puzzle.cells:
        names = [a.name for a in cell.valid_answers]
        assert len(names) == len(set(names))


def test_extra_members_can_never_satisfy_a_stat_axis():
    """Roster memberships carry no stats, so accepting one against "1,400+ Rec Yds" would be
    asserting a statistical achievement we have no evidence for. `Filter` rejects them on a
    missing field, and this pins that rather than trusting it."""
    big = {"receiving_yards": 1500.0, "receptions": 95.0, "receiving_tds": 14.0}
    seasons = [_season(f"{team}Big{i}", team, 2000 + i, stats=big)
               for team in ["SF", "GB", "DAL"] for i in range(4)]
    extras = [RosterMember(f"NoStats{i}", team, 2000 + i)
              for team in ["SF", "GB", "DAL"] for i in range(4)]
    puzzle = grid.generate_grid(seasons, sport="nfl", date="2026-07-08",
                               archetypes=TEAMS_X_STATS, max_attempts=500,
                               extra_members=extras)
    assert puzzle is not None
    all_names = {a.name for cell in puzzle.cells for a in cell.valid_answers}
    assert not any(n.startswith("NoStats") for n in all_names)


# MARK: the mint window (`grid_dates`) and the pool backfill it enables
#
# `run_grid` minted exactly today+tomorrow until 2026-07-27. That is the right *daily* window
# but it caps the pool at ~1 board per sport per day, and the pool is what the Grid's "new
# random board" draws from — it stood at nfl 13 / nba 12 / tennis 12 / soccer 3 / baseball 1,
# thin enough that "random" barely meant anything.

import datetime as dt

from tools.ingest.main import grid_dates


def test_default_window_is_today_and_tomorrow():
    """The daily contract, unchanged: pick() prefers the row whose active_date is the current
    UTC day, so a missing next-day row silently drops every player between 00:00 UTC and the
    morning cron back to the modulo pick over old boards."""
    today = dt.date.today()
    assert grid_dates(today, 2) == [today.isoformat(),
                                    (today + dt.timedelta(days=1)).isoformat()]


def test_window_spans_consecutive_days_from_an_explicit_start():
    assert grid_dates(dt.date(2026, 1, 30), 4) == [
        "2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02"]


def test_a_single_day_window_is_legal_but_an_empty_one_is_not():
    assert grid_dates(dt.date(2026, 1, 1), 1) == ["2026-01-01"]
    with pytest.raises(ValueError):
        grid_dates(dt.date(2026, 1, 1), 0)


def test_backfilling_a_wide_window_yields_distinct_boards_not_the_same_one_repeated():
    """The point of a deep pool is *variety*, so a backfill must not mint 30 copies of one
    board. `run_grid` threads its accumulating `recently_served` set through every date in the
    window, which is what forces each new board to be a combo no earlier one used."""
    seasons = []
    for team in ["SF", "GB", "DAL", "NYG", "CHI", "SEA", "MIA", "KC"]:
        for decade in [1980, 1990, 2000, 2010, 2020]:
            for i in range(3):
                seasons.append(_season(f"{team}{decade}Player{i}", team, decade + i))
    served: set[tuple[str, str]] = set()
    boards = []
    for date in grid_dates(dt.date(2026, 8, 1), 30):
        puzzle = grid.generate_grid(seasons, sport="nfl", date=date, recently_served=served)
        assert puzzle is not None, f"backfill went dry at {date}"
        served.add(grid.combo_key(puzzle.rows, puzzle.cols))
        boards.append(puzzle)
    assert len(served) == 30
    # Depth in shape too, not just in axis sets — a pool of 30 teams-x-decades boards is a
    # thinner pool than the archetype rotation can actually offer.
    assert len({b.archetype for b in boards}) > 1


# MARK: run_grid over a backfill window (upsert path, fully stubbed — no network)

from tools.ingest import main as ingest_main
from tools.ingest import upsert as ingest_upsert


def _raw_rows(sport, teams, decades):
    """`fetch_player_seasons`-shaped dicts (the live catalog's column names)."""
    return [{"name": f"{t}{d}Player{i}", "team_abbr": t, "season_year": d + i, "sport": sport,
             "position": "G", "stats": {"points": 1500.0}, "league": ""}
            for t in teams for d in decades for i in range(3)]


@pytest.fixture
def stub_supabase(monkeypatch):
    """Every network edge of run_grid, replaced. Returns the recorder the tests assert on."""
    calls = {"id_lookups": [], "upserts": [], "history": []}
    monkeypatch.setattr(ingest_main, "load_dotenv", lambda: None)
    monkeypatch.setattr(ingest_upsert, "fetch_grid_history", lambda since: [])
    monkeypatch.setattr(ingest_upsert, "fetch_player_seasons",
                        lambda sport: _raw_rows(sport, ["BOS", "LAL", "CHI", "NYK", "PHI",
                                                        "MIA", "GSW", "DET"],
                                                [1980, 1990, 2000, 2010, 2020]))
    monkeypatch.setattr(ingest_upsert, "upsert_grid",
                        lambda rows: (calls["upserts"].append([r["id"] for r in rows]), len(rows))[1])
    monkeypatch.setattr(ingest_upsert, "upsert_grid_history",
                        lambda rows: (calls["history"].extend(rows), len(rows))[1])
    return calls


def test_backfill_never_re_mints_a_date_that_already_has_a_board(stub_supabase, monkeypatch):
    """The immutability rule survives the wider window: generation is deterministic per
    (sport, date) only against a FIXED catalog, so re-minting a live date would swap a board's
    content under a player who already opened it. A backfill may only ever ADD."""
    already = {"grid-nba-2026-08-02", "grid-nba-2026-08-04"}
    monkeypatch.setattr(ingest_upsert, "fetch_existing_puzzle_ids",
                        lambda ids: {i for i in ids if i in already})

    assert ingest_main.run_grid(["nba"], upsert=True, dry_run=False,
                                start=dt.date(2026, 8, 1), days=5) == 0

    minted = [i for batch in stub_supabase["upserts"] for i in batch]
    assert minted == ["grid-nba-2026-08-01", "grid-nba-2026-08-03", "grid-nba-2026-08-05"]
    assert not already & set(minted)
    assert [h["served_date"] for h in stub_supabase["history"]] == [
        "2026-08-01", "2026-08-03", "2026-08-05"]


def test_a_deep_backfill_chunks_the_skip_check_instead_of_one_giant_url(stub_supabase,
                                                                       monkeypatch):
    """`fetch_existing_puzzle_ids` sends the id list as a PostgREST `id=in.(...)` GET, so it
    rides in the URL. Ten ids always fit; 500 do not, and blowing the server's URL cap would
    fail the backfill at its very first call."""
    seen: list[int] = []

    def _lookup(ids):
        seen.append(len(ids))
        return set(ids)          # everything already minted -> no generation, no writes

    monkeypatch.setattr(ingest_upsert, "fetch_existing_puzzle_ids", _lookup)

    assert ingest_main.run_grid(["nba", "soccer"], upsert=True, dry_run=False,
                                start=dt.date(2026, 8, 1), days=250) == 0

    assert sum(seen) == 500                                   # 2 sports x 250 dates
    assert max(seen) <= ingest_main.GRID_ID_LOOKUP_CHUNK
    assert stub_supabase["upserts"] == []                     # nothing re-minted


def test_a_deep_backfill_chunks_the_upsert_so_no_request_carries_the_whole_pool(stub_supabase,
                                                                               monkeypatch):
    """Grid `content` is the heaviest payload this pipeline writes (~70 KB per NFL board).
    upsert.py batches every table at 200 rows — right for 1 KB catalog rows, ~14 MB per
    request for these."""
    monkeypatch.setattr(ingest_upsert, "fetch_existing_puzzle_ids", lambda ids: set())

    assert ingest_main.run_grid(["nba"], upsert=True, dry_run=False,
                                start=dt.date(2026, 8, 1), days=60) == 0

    sizes = [len(batch) for batch in stub_supabase["upserts"]]
    assert sum(sizes) == 60
    assert max(sizes) <= ingest_main.GRID_UPSERT_CHUNK
