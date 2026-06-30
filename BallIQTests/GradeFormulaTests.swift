import XCTest
@testable import BallIQ

/// Locks the Swift grade port to the Python pipeline (`tools/ingest/grade.py` +
/// `tests/test_grade.py`). Exact values were computed from the same formula, so the
/// creator's live preview ranks identically to a pipeline-generated daily.
final class GradeFormulaTests: XCTestCase {

    func testExactParityWithPipeline() {
        // Derrick Henry 2020 (nfl_rb): see tools/ingest dry-run → 80.6
        let henry = ["rushing_yards": 2027.0, "rushing_tds": 17, "ypc": 5.4]
        XCTAssertEqual(GradeFormula.grade(henry, scale: "nfl_rb"), 80.6, accuracy: 0.001)

        // Michael Jordan 1987 (nba_scorer): → 78.8
        let jordan = ["ppg": 37.1, "ts_pct": 0.562, "apg": 4.6]
        XCTAssertEqual(GradeFormula.grade(jordan, scale: "nba_scorer"), 78.8, accuracy: 0.001)
    }

    func testRbMonotonicInYards() {
        let base = ["rushing_tds": 10.0, "ypc": 4.5]
        let low = GradeFormula.grade(base.merging(["rushing_yards": 1200]) { _, b in b }, scale: "nfl_rb")
        let high = GradeFormula.grade(base.merging(["rushing_yards": 1900]) { _, b in b }, scale: "nfl_rb")
        XCTAssertGreaterThan(high, low)
    }

    func testRb2000OutranksRole() {
        let elite = ["rushing_yards": 2027.0, "rushing_tds": 17, "ypc": 5.4]
        let role = ["rushing_yards": 1100.0, "rushing_tds": 6, "ypc": 4.2]
        XCTAssertGreaterThan(GradeFormula.grade(elite, scale: "nfl_rb"),
                             GradeFormula.grade(role, scale: "nfl_rb"))
    }

    func testQbInterceptionsHurt() {
        let clean = ["passing_yards": 4800.0, "passing_tds": 40, "interceptions": 6]
        let sloppy = ["passing_yards": 4800.0, "passing_tds": 40, "interceptions": 20]
        XCTAssertGreaterThan(GradeFormula.grade(clean, scale: "nfl_qb"),
                             GradeFormula.grade(sloppy, scale: "nfl_qb"))
    }

    func testJordanOutranksCarter() {
        let jordan = ["ppg": 37.1, "ts_pct": 0.562, "apg": 4.6]
        let carter = ["ppg": 27.6, "ts_pct": 0.521, "apg": 3.9]
        XCTAssertGreaterThan(GradeFormula.grade(jordan, scale: "nba_scorer"),
                             GradeFormula.grade(carter, scale: "nba_scorer"))
    }

    func testGradeBounded() {
        let monster = ["rushing_yards": 9999.0, "rushing_tds": 99, "ypc": 12]
        let empty = ["rushing_yards": 0.0]
        XCTAssertGreaterThanOrEqual(GradeFormula.grade(empty, scale: "nfl_rb"), 0)
        XCTAssertLessThanOrEqual(GradeFormula.grade(monster, scale: "nfl_rb"), 100)
    }

    // MARK: - Fantasy-point scales (raw points min-maxed to 0-100; locked to grade.py `_FANTASY`)

    func testFantasyPprExactGrade() {
        // Raw 145 + 194.7 + 96 = 435.7 pts → (435.7-40)/(450-40) * 100 = 96.5
        let kupp = ["receptions": 145.0, "receiving_yards": 1947, "receiving_tds": 16]
        XCTAssertEqual(GradeFormula.grade(kupp, scale: "nfl_skill_ppr"), 96.5, accuracy: 0.001)
        // Rushing-only: raw 202.7 + 102 = 304.7 pts → (304.7-40)/410 * 100 = 64.6
        let henry = ["rushing_yards": 2027.0, "rushing_tds": 17, "ypc": 5.4]
        XCTAssertEqual(GradeFormula.grade(henry, scale: "nfl_skill_ppr"), 64.6, accuracy: 0.001)
    }

    func testFantasyQbExactGrade() {
        // Raw 192 + 160 − 12 = 340.0 pts → (340-100)/(450-100) * 100 = 68.6
        let qb = ["passing_yards": 4800.0, "passing_tds": 40, "interceptions": 6]
        XCTAssertEqual(GradeFormula.grade(qb, scale: "nfl_qb_fantasy"), 68.6, accuracy: 0.001)
    }

    func testFantasyNbaExactGrade() {
        // Raw 37.1 + 6.24 + 6.9 + 8.7 + 4.5 = 63.4 pts → (63.4-15)/(75-15) * 100 = 80.7
        let jordan = ["ppg": 37.1, "rpg": 5.2, "apg": 4.6, "spg": 2.9, "bpg": 1.5]
        XCTAssertEqual(GradeFormula.grade(jordan, scale: "nba_fantasy"), 80.7, accuracy: 0.001)
    }

    func testFantasyPprRewardsReceptionsAndTds() {
        // The audit fix: a reception/TD-heavy WR now outranks a yards-only WR.
        let heavy = ["receptions": 120.0, "receiving_yards": 1300, "receiving_tds": 13]
        let yards = ["receptions": 65.0, "receiving_yards": 1500, "receiving_tds": 5]
        XCTAssertGreaterThan(GradeFormula.grade(heavy, scale: "nfl_skill_ppr"),
                             GradeFormula.grade(yards, scale: "nfl_skill_ppr"))
    }

    func testTemplateBuildsGradedCardWithFormattedStats() {
        let template = CreationTemplate.all.first { $0.id == "nfl_rb" }!
        let season = CatalogSeason(id: "derrick-henry-2020", sport: .nfl, name: "Derrick Henry",
                                   teamAbbr: "TEN", seasonYear: 2020, position: "RB",
                                   stats: ["rushing_yards": 2027, "rushing_tds": 17, "ypc": 5.4])
        let card = template.playerSeason(for: season)
        XCTAssertEqual(card.grade, 80.6, accuracy: 0.001)
        XCTAssertEqual(card.stats.first { $0.label == "Rush Yds" }?.value, "2,027")
        XCTAssertEqual(card.stats.first { $0.label == "YPC" }?.value, "5.4")
    }
}
