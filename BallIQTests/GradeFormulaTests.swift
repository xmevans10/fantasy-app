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

    // MARK: - Fantasy-point scales (grade IS the raw point total; locked to grade.py `_FANTASY`)

    func testFantasyPprExactGrade() {
        let kupp = ["receptions": 145.0, "receiving_yards": 1947, "receiving_tds": 16]
        XCTAssertEqual(GradeFormula.grade(kupp, scale: "nfl_skill_ppr"), 435.7, accuracy: 0.001)
        let henry = ["rushing_yards": 2027.0, "rushing_tds": 17, "ypc": 5.4]
        XCTAssertEqual(GradeFormula.grade(henry, scale: "nfl_skill_ppr"), 304.7, accuracy: 0.001)
    }

    func testFantasyQbExactGrade() {
        let qb = ["passing_yards": 4800.0, "passing_tds": 40, "interceptions": 6]
        XCTAssertEqual(GradeFormula.grade(qb, scale: "nfl_qb_fantasy"), 340.0, accuracy: 0.001)
    }

    func testFantasyNbaExactGrade() {
        // 1986-87 Jordan season TOTALS as ingest derives them (per-game × 82 games) —
        // NBA grades are season-long like every other sport. Mirrors test_grade.py.
        let jordan = ["points": 3042.0, "rebounds": 426, "assists": 377,
                      "steals": 238, "blocks": 123]
        XCTAssertEqual(GradeFormula.grade(jordan, scale: "nba_fantasy"), 5201.7, accuracy: 0.001)
    }

    func testFantasyNbaIgnoresPerGameAverages() {
        // Averages-only stats grade 0 — the loud failure if a catalog row is missing
        // its derived totals, rather than a silently per-game-scaled grade.
        let averagesOnly = ["ppg": 37.1, "rpg": 5.2, "apg": 4.6, "spg": 2.9, "bpg": 1.5]
        XCTAssertEqual(GradeFormula.grade(averagesOnly, scale: "nba_fantasy"), 0.0, accuracy: 0.001)
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

    /// M17: a season row (no career flag at all, e.g. decoded from the bundled fallback)
    /// must not be mistaken for a career row.
    func testCatalogSeasonWithNoCareerFlagIsNotCareer() {
        let season = CatalogSeason(id: "derrick-henry-2020", sport: .nfl, name: "Derrick Henry",
                                   teamAbbr: "TEN", seasonYear: 2020, position: "RB", stats: [:])
        XCTAssertFalse(season.isCareer)
        XCTAssertEqual(season.subtitle, "TEN · 2020")
    }

    /// M17: a career row's subtitle reads the full span, matching PlayerSeason.subtitle.
    func testCatalogSeasonCareerSubtitleReadsFullSpan() {
        let career = CatalogSeason(id: "derrick-henry-career", sport: .nfl, name: "Derrick Henry",
                                   teamAbbr: "TEN", seasonYear: 2023, position: "RB", stats: [:],
                                   career: true, firstYear: 2016, lastYear: 2023)
        XCTAssertTrue(career.isCareer)
        XCTAssertEqual(career.subtitle, "TEN · 2016-2023")
    }

    /// M17: `CatalogQuery.grain` defaults to season-only — the same scope every query
    /// had before career (and later single-game) rows existed in the catalog — so
    /// free-form/season-template search never regresses to seeing another grain mixed in.
    func testCatalogQueryDefaultsToSeasonOnly() {
        XCTAssertEqual(CatalogQuery().grain, .season)
        XCTAssertEqual(CatalogQuery(sport: .nfl).grain, .season)
    }

    /// A single-game catalog row's subtitle reads "vs OPP · date · year" — matching
    /// PlayerSeason.subtitle's own single-game format (MLB/NBA, which use `gameDate`
    /// rather than NFL's `week`-based "Wk W" label).
    func testCatalogSeasonGameSubtitleReadsOpponentAndDate() {
        let game = CatalogSeason(id: "aaron-judge-2022-wk12", sport: .baseball, name: "Aaron Judge",
                                 teamAbbr: "NYY", seasonYear: 2022, position: "H", stats: [:],
                                 week: 12, opponent: "BOS", gameDate: "Apr 8")
        XCTAssertTrue(game.isGame)
        XCTAssertEqual(game.subtitle, "vs BOS · Apr 8 · 2022")
    }
}
