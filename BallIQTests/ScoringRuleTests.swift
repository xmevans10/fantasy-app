import XCTest
@testable import BallIQ

/// Locks the composable `ScoringRule` presets to the parity-locked `GradeFormula` scales,
/// and checks era-adjusted normalization behaves sensibly with and without baselines.
final class ScoringRuleTests: XCTestCase {

    // MARK: - Preset parity with GradeFormula (and thus tools/ingest/grade.py)

    func testPresetsMatchGradeFormulaExactly() {
        let cases: [(String, Sport, Int, [String: Double])] = [
            ("nfl_rb", .nfl, 2020, ["rushing_yards": 2027, "rushing_tds": 17, "ypc": 5.4]),
            ("nfl_wr", .nfl, 2021, ["receiving_yards": 1947, "receiving_tds": 16, "receptions": 145]),
            ("nfl_qb", .nfl, 2018, ["passing_yards": 4800, "passing_tds": 40, "interceptions": 6]),
            ("nba_scorer", .nba, 1987, ["ppg": 37.1, "ts_pct": 0.562, "apg": 4.6]),
            ("nba_big", .nba, 2000, ["ppg": 24.0, "rpg": 12.0, "bpg": 2.5]),
            ("nba_playmaker", .nba, 2017, ["apg": 10.0, "ppg": 23.0, "ts_pct": 0.58]),
        ]
        for (key, sport, year, stats) in cases {
            let rule = ScoringRule.preset(key)!
            let expected = GradeFormula.grade(stats, scale: key)
            let actual = rule.grade(stats: stats, sport: sport, position: "X", seasonYear: year)
            XCTAssertEqual(actual, expected, accuracy: 0.001, "preset \(key) diverged from GradeFormula")
        }
    }

    // MARK: - Fantasy-points presets (parity with GradeFormula / grade.py)

    func testFantasyPresetsMatchGradeFormulaExactly() {
        let cases: [(String, Sport, Int, [String: Double])] = [
            ("nfl_skill_ppr", .nfl, 2021, ["receptions": 145, "receiving_yards": 1947, "receiving_tds": 16]),
            ("nfl_qb_fantasy", .nfl, 2018, ["passing_yards": 4800, "passing_tds": 40, "interceptions": 6]),
            ("nba_fantasy", .nba, 1987, ["ppg": 37.1, "rpg": 5.2, "apg": 4.6, "spg": 2.9, "bpg": 1.5]),
        ]
        for (key, sport, year, stats) in cases {
            let rule = ScoringRule.preset(key)!
            XCTAssertTrue(rule.isPoints, "preset \(key) should be a points rule")
            let expected = GradeFormula.grade(stats, scale: key)
            let actual = rule.grade(stats: stats, sport: sport, position: "X", seasonYear: year)
            XCTAssertEqual(actual, expected, accuracy: 0.001, "fantasy preset \(key) diverged from GradeFormula")
        }
    }

    func testFantasyPprExactGrade() {
        // Raw 435.7 pts → (435.7-40)/410 * 100 = 96.5
        let kupp = ["receptions": 145.0, "receiving_yards": 1947, "receiving_tds": 16]
        let g = ScoringRule.preset("nfl_skill_ppr")!.grade(stats: kupp, sport: .nfl, position: "WR", seasonYear: 2021)
        XCTAssertEqual(g, 96.5, accuracy: 0.001)
    }

    func testPointsRuleWithoutDisplayScaleShowsRawTotal() {
        // A points rule built without a displayScale (e.g. ad-hoc, not a shipped preset)
        // falls back to showing the raw total — confirms the fallback path, not just presets.
        let rule = ScoringRule(terms: [.init(stat: "receptions", weight: 1, higherWins: true,
                                             norm: .points(perUnit: 1))])
        XCTAssertNil(rule.displayScale)
        let g = rule.grade(stats: ["receptions": 100.0], sport: .nfl, position: "WR", seasonYear: 2021)
        XCTAssertEqual(g, 100.0, accuracy: 0.001)
    }

    func testEraPointsFallsBackToRawWhenNoBaseline() {
        // With no baselines the era volume index is 1.0, so era-adjusted == raw points.
        let rule = ScoringRule.preset("nfl_skill_ppr")!
        let stats = ["receptions": 100.0, "receiving_yards": 1200, "receiving_tds": 10]
        let plain = rule.grade(stats: stats, sport: .nfl, position: "WR", seasonYear: 2020)
        let era = rule.eraAdjusted(true).grade(stats: stats, sport: .nfl, position: "WR", seasonYear: 2020,
                                               baselines: StatBaselines())
        XCTAssertEqual(plain, era, accuracy: 0.001)
    }

    func testEraPointsRewardsScarceEra() {
        // Same 100 catches: extraordinary in a low-volume era (mean 60), average in a high one
        // (mean 100). Global mean pools to 80, so the index inflates 2004 and deflates 2024.
        let table: [String: StatBaselines.Stat] = [
            StatBaselines.key(sport: "nfl", position: "WR", stat: "receptions", year: 2004):
                .init(mean: 60, std: 10, count: 40),
            StatBaselines.key(sport: "nfl", position: "WR", stat: "receptions", year: 2024):
                .init(mean: 100, std: 10, count: 40),
        ]
        let baselines = StatBaselines(table: table)
        let rule = ScoringRule(terms: [.init(stat: "receptions", weight: 1, higherWins: true,
                                             norm: .points(perUnit: 1))]).eraAdjusted(true)
        let stats = ["receptions": 100.0]
        let g2004 = rule.grade(stats: stats, sport: .nfl, position: "WR", seasonYear: 2004, baselines: baselines)
        let g2024 = rule.grade(stats: stats, sport: .nfl, position: "WR", seasonYear: 2024, baselines: baselines)
        XCTAssertEqual(g2004, 133.3, accuracy: 0.05, "100 catches × (80/60) ≈ 133.3")
        XCTAssertEqual(g2024, 80.0, accuracy: 0.05, "100 catches × (80/100) = 80.0")
        XCTAssertGreaterThan(g2004, g2024, "scarce-era production should outrank the same raw total in a high-volume era")
    }

    func testCustomWeightsAreNormalized() {
        // A single-term rule: any positive weight yields the same component-driven grade.
        let w1 = ScoringRule(terms: [.init(stat: "rushing_yards", weight: 1,
                                            higherWins: true, norm: .fixed(.init(lo: 850, hi: 2100)))])
        let w7 = ScoringRule(terms: [.init(stat: "rushing_yards", weight: 7,
                                            higherWins: true, norm: .fixed(.init(lo: 850, hi: 2100)))])
        let stats = ["rushing_yards": 1475.0]
        XCTAssertEqual(w1.grade(stats: stats, sport: .nfl, position: "RB", seasonYear: 2020),
                       w7.grade(stats: stats, sport: .nfl, position: "RB", seasonYear: 2020), accuracy: 0.001)
    }

    // MARK: - Era adjustment

    func testEraAdjustedFallsBackToFixedWhenNoBaseline() {
        let fixed = ScoringRule.preset("nfl_rb")!
        let era = fixed.eraAdjusted(true)
        let stats = ["rushing_yards": 1500.0, "rushing_tds": 12, "ypc": 4.8]
        // With an empty baseline catalog, era-adjusted must equal the fixed grade.
        XCTAssertEqual(era.grade(stats: stats, sport: .nfl, position: "RB", seasonYear: 2020, baselines: StatBaselines()),
                       fixed.grade(stats: stats, sport: .nfl, position: "RB", seasonYear: 2020), accuracy: 0.001)
    }

    func testEraAdjustedRanksRelativeToSeasonDistribution() {
        // Same raw value (1400 yds), two seasons with very different league context.
        let table: [String: StatBaselines.Stat] = [
            StatBaselines.key(sport: "nfl", position: "WR", stat: "receiving_yards", year: 2004):
                .init(mean: 1400, std: 200, count: 40),   // average for 2004 → ~50
            StatBaselines.key(sport: "nfl", position: "WR", stat: "receiving_yards", year: 2024):
                .init(mean: 900, std: 200, count: 40),    // well above 2024 mean → high
        ]
        let baselines = StatBaselines(table: table)
        let rule = ScoringRule(terms: [.init(stat: "receiving_yards", weight: 1, higherWins: true,
                                             norm: .eraAdjusted(fallback: .init(lo: 850, hi: 1950)))])
        let stats = ["receiving_yards": 1400.0]
        let g2004 = rule.grade(stats: stats, sport: .nfl, position: "WR", seasonYear: 2004, baselines: baselines)
        let g2024 = rule.grade(stats: stats, sport: .nfl, position: "WR", seasonYear: 2024, baselines: baselines)
        XCTAssertEqual(g2004, 50, accuracy: 0.5, "value at the era mean should grade ~50")
        XCTAssertGreaterThan(g2024, g2004, "an era-relative outlier should outrank an era-average season")
    }

    func testEraAdjustedHonorsLowerWins() {
        let table: [String: StatBaselines.Stat] = [
            StatBaselines.key(sport: "nfl", position: "QB", stat: "interceptions", year: 2020):
                .init(mean: 12, std: 4, count: 30),
        ]
        let baselines = StatBaselines(table: table)
        let rule = ScoringRule(terms: [.init(stat: "interceptions", weight: 1, higherWins: false,
                                             norm: .eraAdjusted(fallback: .init(lo: 4, hi: 24)))])
        let clean = rule.grade(stats: ["interceptions": 4], sport: .nfl, position: "QB", seasonYear: 2020, baselines: baselines)
        let sloppy = rule.grade(stats: ["interceptions": 20], sport: .nfl, position: "QB", seasonYear: 2020, baselines: baselines)
        XCTAssertGreaterThan(clean, sloppy, "fewer interceptions should score higher")
    }
}
