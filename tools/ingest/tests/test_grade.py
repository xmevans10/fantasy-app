"""Grade-ordering tests — the formula must rank seasons the way a fan reading a
reference page would. These are the defensibility guarantees for the Keep4 answer.
"""
from tools.ingest.grade import grade


def test_rb_more_yards_outranks_fewer():
    elite = {"rushing_yards": 2027, "rushing_tds": 17, "ypc": 5.4}
    decent = {"rushing_yards": 1100, "rushing_tds": 6, "ypc": 4.2}
    assert grade(elite, "nfl_rb") > grade(decent, "nfl_rb")


def test_rb_monotonic_in_primary_stat():
    base = {"rushing_tds": 10, "ypc": 4.5}
    low = grade({**base, "rushing_yards": 1200}, "nfl_rb")
    high = grade({**base, "rushing_yards": 1900}, "nfl_rb")
    assert high > low


def test_qb_interceptions_hurt():
    clean = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 6}
    sloppy = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 20}
    assert grade(clean, "nfl_qb") > grade(sloppy, "nfl_qb")


def test_wr_more_yards_outranks_fewer():
    moss = {"receiving_yards": 1632, "receiving_tds": 17, "receptions": 111}
    role = {"receiving_yards": 1050, "receiving_tds": 6, "receptions": 70}
    assert grade(moss, "nfl_wr") > grade(role, "nfl_wr")


def test_nba_jordan_outranks_carter():
    jordan = {"ppg": 37.1, "ts_pct": 0.562, "apg": 4.6}
    carter = {"ppg": 27.6, "ts_pct": 0.521, "apg": 3.9}
    assert grade(jordan, "nba_scorer") > grade(carter, "nba_scorer")


def test_nba_big_rebounds_matter():
    a = {"ppg": 22.0, "rpg": 14.0, "bpg": 2.4}
    b = {"ppg": 22.0, "rpg": 9.6, "bpg": 2.4}
    assert grade(a, "nba_big") > grade(b, "nba_big")


def test_grade_bounded_0_100():
    monster = {"rushing_yards": 9999, "rushing_tds": 99, "ypc": 12.0}
    empty = {"rushing_yards": 0, "rushing_tds": 0, "ypc": 0}
    assert 0.0 <= grade(empty, "nfl_rb") <= grade(monster, "nfl_rb") <= 100.0


# ── Fantasy-point scales (grade IS the raw point total; locked values mirror
# GradeFormula/ScoringRule in Swift) ──

def test_fantasy_ppr_exact_grade():
    wr = {"receptions": 145, "receiving_yards": 1947, "receiving_tds": 16}
    assert grade(wr, "nfl_skill_ppr") == 435.7   # 145 + 194.7 + 96
    rb = {"rushing_yards": 2027, "rushing_tds": 17, "ypc": 5.4}
    assert grade(rb, "nfl_skill_ppr") == 304.7   # 202.7 + 102


def test_fantasy_qb_exact_grade():
    qb = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 6}
    assert grade(qb, "nfl_qb_fantasy") == 340.0   # 192 + 160 - 12


def test_unified_nfl_fantasy_covers_all_positions():
    # The unified scale scores a QB and a WR on the same axis: it reduces to the
    # QB formula for pure passers and the PPR formula for pure receivers.
    qb = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 6}
    wr = {"receptions": 145, "receiving_yards": 1947, "receiving_tds": 16}
    assert grade(qb, "nfl_fantasy") == grade(qb, "nfl_qb_fantasy") == 340.0
    assert grade(wr, "nfl_fantasy") == grade(wr, "nfl_skill_ppr") == 435.7
    # A dual-threat line earns both components at once.
    dual = {"passing_yards": 4000, "passing_tds": 30, "rushing_yards": 800, "rushing_tds": 8}
    assert grade(dual, "nfl_fantasy") == 408.0   # 160 + 120 + 80 + 48


def test_fantasy_qb_interceptions_penalize():
    clean = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 6}
    sloppy = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 20}
    assert grade(clean, "nfl_qb_fantasy") > grade(sloppy, "nfl_qb_fantasy")


def test_fantasy_nba_exact_grade():
    jordan = {"ppg": 37.1, "rpg": 5.2, "apg": 4.6, "spg": 2.9, "bpg": 1.5}
    assert grade(jordan, "nba_fantasy") == 63.4   # 37.1 + 6.24 + 6.9 + 8.7 + 4.5


def test_baseball_hitter_exact_grade():
    # Real 2022 Aaron Judge line (verified live against statsapi.mlb.com this session).
    judge = {"hits": 177, "doubles": 28, "triples": 0, "home_runs": 62, "runs": 133,
             "rbi": 131, "base_on_balls": 111, "stolen_bases": 16}
    assert grade(judge, "baseball_hitter_fantasy") == 798.0


def test_baseball_pitcher_exact_grade():
    # Real 2023 Gerrit Cole line (AL Cy Young season).
    cole = {"innings_pitched": 209.0, "wins": 15, "saves": 0, "strike_outs": 222,
            "earned_runs": 61, "base_on_balls": 48}
    assert grade(cole, "baseball_pitcher_fantasy") == 421.0


def test_baseball_pitcher_walks_and_earned_runs_hurt():
    clean = {"innings_pitched": 200.0, "strike_outs": 200, "wins": 15, "saves": 0,
             "earned_runs": 40, "base_on_balls": 40}
    sloppy = {**clean, "earned_runs": 80, "base_on_balls": 90}
    assert grade(clean, "baseball_pitcher_fantasy") > grade(sloppy, "baseball_pitcher_fantasy")


def test_soccer_attacker_exact_grade():
    haaland = {"appearances": 35, "goals": 36, "assists": 8}
    assert grade(haaland, "soccer_attacker_fantasy") == 239.0


def test_soccer_defender_exact_grade():
    keeper = {"appearances": 38, "goals": 0, "assists": 0, "clean_sheets": 24}
    assert grade(keeper, "soccer_defender_fantasy") == 115.0


def test_tennis_exact_grade():
    djokovic_2015 = {"matches_won": 82, "matches_lost": 6, "titles": 11, "grand_slams": 3}
    assert grade(djokovic_2015, "tennis_fantasy") == 257.0


def test_tennis_grand_slams_dominate_the_total():
    # A 3-slam season must always outrank a slam-less one, even with fewer match wins.
    slam_season = {"matches_won": 55, "matches_lost": 8, "titles": 5, "grand_slams": 3}
    grind_season = {"matches_won": 70, "matches_lost": 20, "titles": 3, "grand_slams": 0}
    assert grade(slam_season, "tennis_fantasy") > grade(grind_season, "tennis_fantasy")


def test_fantasy_grade_monotonic_in_volume():
    monster = {"receptions": 999, "receiving_yards": 9999, "receiving_tds": 99}
    empty = {"receptions": 0, "receiving_yards": 0, "receiving_tds": 0}
    assert grade(empty, "nfl_skill_ppr") == 0.0
    assert grade(monster, "nfl_skill_ppr") > grade(empty, "nfl_skill_ppr")


def test_fantasy_ppr_rewards_receptions_and_tds():
    # The audit fix: a reception/TD-heavy WR now outranks a yards-only WR that the
    # old yards-weighted nfl_wr scale would have favored.
    heavy = {"receptions": 120, "receiving_yards": 1300, "receiving_tds": 13}
    yards = {"receptions": 65, "receiving_yards": 1500, "receiving_tds": 5}
    assert grade(heavy, "nfl_skill_ppr") > grade(yards, "nfl_skill_ppr")


# ── Single-game scales (same PPR coefficients — see grade.py) ──

def test_game_scale_matches_season_coefficients():
    # Grain only changes the typical magnitude of `stats`, not the formula itself.
    monster_game = {"receptions": 13, "receiving_yards": 270, "receiving_tds": 3}
    assert grade(monster_game, "nfl_skill_ppr_game") == 58.0   # 13 + 27 + 18
    assert grade(monster_game, "nfl_skill_ppr_game") == grade(monster_game, "nfl_skill_ppr")


# ── Era-adjusted fantasy grading (M10; locked values mirrored by ScoringRuleTests) ──

from tools.ingest.grade import BaselineTable, era_index, grade_era

_ERA_ROWS = [
    # fantasy_total pseudo-stat (baselines.py): qualified-QB fantasy totals grew 2002 → 2020.
    # global (count-weighted) mean = (202·10 + 303·10) / 20 = 252.5.
    {"sport": "nfl", "position": "QB", "stat": "fantasy_total", "year": 2002, "mean": 202, "std": 1, "count": 10},
    {"sport": "nfl", "position": "QB", "stat": "fantasy_total", "year": 2020, "mean": 303, "std": 1, "count": 10},
]
_QB_LINE = {"passing_yards": 3000, "passing_tds": 30, "interceptions": 10,
            "rushing_yards": 300, "rushing_tds": 3}   # raw nfl_qb_fantasy = 268.0


def test_era_index_locked_values():
    # 252.5/202 = 1.25 exactly; 252.5/303 = 0.8333…
    table = BaselineTable(_ERA_ROWS)
    assert era_index("nfl_qb_fantasy", "nfl", "QB", 2002, table) == 1.25
    assert abs(era_index("nfl_qb_fantasy", "nfl", "QB", 2020, table) - 252.5 / 303) < 1e-9


def test_grade_era_locked_values():
    table = BaselineTable(_ERA_ROWS)
    assert grade_era(_QB_LINE, "nfl_qb_fantasy", "nfl", "QB", 2002, table) == 335.0  # 268 × 1.25
    assert grade_era(_QB_LINE, "nfl_qb_fantasy", "nfl", "QB", 2020, table) == 223.3  # 268 × 0.8333


def test_era_index_thin_year_falls_back():
    # A year with no rows (or all below MIN_ERA_SAMPLES) gets index 1.0 → grade == raw.
    table = BaselineTable(_ERA_ROWS)
    assert era_index("nfl_qb_fantasy", "nfl", "QB", 1988, table) == 1.0
    assert grade_era(_QB_LINE, "nfl_qb_fantasy", "nfl", "QB", 1988, table) == 268.0
    thin = BaselineTable([{**r, "count": 5} for r in _ERA_ROWS])
    assert era_index("nfl_qb_fantasy", "nfl", "QB", 2002, thin) == 1.0


def test_era_preserves_same_year_ordering():
    # The total index is a monotonic rescale within a position-year: raw order == era order.
    table = BaselineTable(_ERA_ROWS)
    better = {**_QB_LINE, "passing_tds": 40}
    from tools.ingest.grade import grade
    assert grade(better, "nfl_qb_fantasy") > grade(_QB_LINE, "nfl_qb_fantasy")
    assert (grade_era(better, "nfl_qb_fantasy", "nfl", "QB", 2002, table)
            > grade_era(_QB_LINE, "nfl_qb_fantasy", "nfl", "QB", 2002, table))


def test_era_theme_assembles_with_adjusted_grades():
    # An era_adjusted theme's pool grades = grade_era, not raw grade.
    from tools.ingest.assemble import grade_pool
    from tools.ingest.models import RawSeason
    from tools.ingest.themes import KEEP4_THEMES

    theme = next(t for t in KEEP4_THEMES if t.key == "nfl-total-fantasy-era")
    seasons = [RawSeason(name=f"QB {y} {i}", team_abbr="KC", season_year=y, sport="nfl",
                         position="QB",
                         stats={**_QB_LINE, "games": 16, "passing_yards": 3000 + i * 100})
               for y in (2002, 2020) for i in range(3)]
    table = BaselineTable(_ERA_ROWS)
    ranked = grade_pool(theme, seasons, table)
    graded = {s.name: g for s, g in ranked}
    # Identical raw lines: the 2002 season must outrank the 2020 one after adjustment.
    assert graded["QB 2002 0"] > graded["QB 2020 0"]
    assert graded["QB 2002 0"] == grade_era(seasons[0].stats, "nfl_fantasy", "nfl", "QB", 2002, table)
