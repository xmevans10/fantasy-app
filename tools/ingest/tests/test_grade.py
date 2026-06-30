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


# ── Fantasy-point scales (raw points min-maxed to 0-100; locked values mirror
# GradeFormula/ScoringRule in Swift) ──

def test_fantasy_ppr_exact_grade():
    # Raw 145 + 194.7 + 96 = 435.7 pts → (435.7-40)/(450-40) * 100 = 96.5
    wr = {"receptions": 145, "receiving_yards": 1947, "receiving_tds": 16}
    assert grade(wr, "nfl_skill_ppr") == 96.5
    # Rushing-only: raw 202.7 + 102 = 304.7 pts → (304.7-40)/410 * 100 = 64.6
    rb = {"rushing_yards": 2027, "rushing_tds": 17, "ypc": 5.4}
    assert grade(rb, "nfl_skill_ppr") == 64.6


def test_fantasy_qb_exact_grade():
    # Raw 192 + 160 - 12 = 340.0 pts → (340-100)/(450-100) * 100 = 68.6
    qb = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 6}
    assert grade(qb, "nfl_qb_fantasy") == 68.6


def test_fantasy_qb_interceptions_penalize():
    clean = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 6}
    sloppy = {"passing_yards": 4800, "passing_tds": 40, "interceptions": 20}
    assert grade(clean, "nfl_qb_fantasy") > grade(sloppy, "nfl_qb_fantasy")


def test_fantasy_nba_exact_grade():
    # Raw 37.1 + 6.24 + 6.9 + 8.7 + 4.5 = 63.4 pts → (63.4-15)/(75-15) * 100 = 80.7
    jordan = {"ppg": 37.1, "rpg": 5.2, "apg": 4.6, "spg": 2.9, "bpg": 1.5}
    assert grade(jordan, "nba_fantasy") == 80.7


def test_fantasy_grade_bounded_0_100():
    monster = {"receptions": 999, "receiving_yards": 9999, "receiving_tds": 99}
    empty = {"receptions": 0, "receiving_yards": 0, "receiving_tds": 0}
    assert 0.0 <= grade(empty, "nfl_skill_ppr") <= grade(monster, "nfl_skill_ppr") <= 100.0


def test_fantasy_ppr_rewards_receptions_and_tds():
    # The audit fix: a reception/TD-heavy WR now outranks a yards-only WR that the
    # old yards-weighted nfl_wr scale would have favored.
    heavy = {"receptions": 120, "receiving_yards": 1300, "receiving_tds": 13}
    yards = {"receptions": 65, "receiving_yards": 1500, "receiving_tds": 5}
    assert grade(heavy, "nfl_skill_ppr") > grade(yards, "nfl_skill_ppr")
