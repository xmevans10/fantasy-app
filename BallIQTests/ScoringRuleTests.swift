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
            ("nfl_fantasy", .nfl, 2019, ["passing_yards": 4000, "passing_tds": 30,
                                         "rushing_yards": 800, "rushing_tds": 8]),
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
        let kupp = ["receptions": 145.0, "receiving_yards": 1947, "receiving_tds": 16]
        let g = ScoringRule.preset("nfl_skill_ppr")!.grade(stats: kupp, sport: .nfl, position: "WR", seasonYear: 2021)
        XCTAssertEqual(g, 435.7, accuracy: 0.001)
    }

    func testFantasyPresetsHaveNoDisplayScale() {
        // The shipped presets show the raw point total, not a 0–100 normalized grade.
        for key in ["nfl_fantasy", "nfl_skill_ppr", "nfl_qb_fantasy", "nba_fantasy"] {
            XCTAssertNil(ScoringRule.preset(key)!.displayScale, "preset \(key) should show raw points")
        }
    }

    func testUnifiedNflFantasyScoresAllPositionsOnOneAxis() {
        // Cross-position fairness: the unified preset reduces to the QB formula for a pure
        // passer and the PPR formula for a pure receiver, so mixing them in one pool is fair.
        let rule = ScoringRule.preset("nfl_fantasy")!
        let qb = ["passing_yards": 4800.0, "passing_tds": 40, "interceptions": 6]
        let wr = ["receptions": 145.0, "receiving_yards": 1947, "receiving_tds": 16]
        XCTAssertEqual(rule.grade(stats: qb, sport: .nfl, position: "QB", seasonYear: 2018), 340.0, accuracy: 0.001)
        XCTAssertEqual(rule.grade(stats: wr, sport: .nfl, position: "WR", seasonYear: 2021), 435.7, accuracy: 0.001)
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
        // Same 100-point raw season: extraordinary in a low-volume era (total mean 60),
        // average in a high one (mean 100). Global pools to 80 → 2004 inflates, 2024 deflates.
        let table: [String: StatBaselines.Stat] = [
            StatBaselines.key(sport: "nfl", position: "WR", stat: ScoringRule.fantasyTotalStat, year: 2004):
                .init(mean: 60, std: 10, count: 40),
            StatBaselines.key(sport: "nfl", position: "WR", stat: ScoringRule.fantasyTotalStat, year: 2024):
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

    // MARK: - Era total index (M10; locked values mirrored by test_grade.py era tests)

    /// Same fixture as tools/ingest/tests/test_grade.py `_ERA_ROWS`: qualified-QB fantasy
    /// totals (the `fantasy_total` pseudo-stat) grew 2002 → 2020; identical locked numbers
    /// on both sides. Count-weighted global mean = (202·10 + 303·10) / 20 = 252.5.
    private static let eraFixture = StatBaselines(table: [
        StatBaselines.key(sport: "nfl", position: "QB", stat: ScoringRule.fantasyTotalStat, year: 2002):
            .init(mean: 202, std: 1, count: 10),
        StatBaselines.key(sport: "nfl", position: "QB", stat: ScoringRule.fantasyTotalStat, year: 2020):
            .init(mean: 303, std: 1, count: 10),
    ])

    private static let qbLine: [String: Double] = [
        "passing_yards": 3000, "passing_tds": 30, "interceptions": 10,
        "rushing_yards": 300, "rushing_tds": 3,   // raw nfl_qb_fantasy = 268.0
    ]

    func testEraTotalIndexLockedValues() {
        // 252.5/202 = 1.25 exactly; 252.5/303 = 0.8333…
        XCTAssertEqual(ScoringRule.eraTotalIndex(sport: .nfl, position: "QB",
                                                 year: 2002, baselines: Self.eraFixture),
                       1.25, accuracy: 1e-9)
        XCTAssertEqual(ScoringRule.eraTotalIndex(sport: .nfl, position: "QB",
                                                 year: 2020, baselines: Self.eraFixture),
                       252.5 / 303, accuracy: 1e-9)
    }

    func testEraGradeLockedValues() {
        let rule = ScoringRule.preset("nfl_qb_fantasy")!.eraAdjusted(true)
        XCTAssertEqual(rule.grade(stats: Self.qbLine, sport: .nfl, position: "QB",
                                  seasonYear: 2002, baselines: Self.eraFixture),
                       335.0, accuracy: 0.001)   // 268 × 1.25
        XCTAssertEqual(rule.grade(stats: Self.qbLine, sport: .nfl, position: "QB",
                                  seasonYear: 2020, baselines: Self.eraFixture),
                       223.3, accuracy: 0.001)   // 268 × 0.8333…
    }

    func testEraThinYearFallsBackToRaw() {
        let rule = ScoringRule.preset("nfl_qb_fantasy")!.eraAdjusted(true)
        XCTAssertEqual(rule.grade(stats: Self.qbLine, sport: .nfl, position: "QB",
                                  seasonYear: 1988, baselines: Self.eraFixture),
                       268.0, accuracy: 0.001, "year with no baselines → index 1.0")
    }

    func testEraPreservesSameYearOrdering() {
        // The total index is a monotonic rescale within a position-year.
        let rule = ScoringRule.preset("nfl_qb_fantasy")!.eraAdjusted(true)
        var better = Self.qbLine; better["passing_tds"] = 40
        XCTAssertGreaterThan(
            rule.grade(stats: better, sport: .nfl, position: "QB", seasonYear: 2002, baselines: Self.eraFixture),
            rule.grade(stats: Self.qbLine, sport: .nfl, position: "QB", seasonYear: 2002, baselines: Self.eraFixture))
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

    // MARK: - Baseball/soccer/tennis presets (parity with grade.py's new `_FANTASY` scales;
    // same locked values as tools/ingest/tests/test_grade.py's new cases — `GradeFormula` is
    // a legacy, runtime-unused parity fixture so these compare directly against grade.py's
    // real numbers instead of adding a third duplicate copy of the same scale data there).

    func testBaseballHitterExactGrade() {
        // Real 2022 Aaron Judge line (verified live against statsapi.mlb.com this session).
        let judge: [String: Double] = ["hits": 177, "doubles": 28, "triples": 0, "home_runs": 62,
                                       "runs": 133, "rbi": 131, "base_on_balls": 111, "stolen_bases": 16]
        let g = ScoringRule.preset("baseball_hitter_fantasy")!
            .grade(stats: judge, sport: .baseball, position: "H", seasonYear: 2022)
        XCTAssertEqual(g, 798.0, accuracy: 0.001)
    }

    func testBaseballPitcherExactGrade() {
        // Real 2023 Gerrit Cole line (AL Cy Young season).
        let cole: [String: Double] = ["innings_pitched": 209.0, "wins": 15, "saves": 0,
                                      "strike_outs": 222, "earned_runs": 61, "base_on_balls": 48]
        let g = ScoringRule.preset("baseball_pitcher_fantasy")!
            .grade(stats: cole, sport: .baseball, position: "P", seasonYear: 2023)
        XCTAssertEqual(g, 421.0, accuracy: 0.001)
    }

    func testSoccerAttackerExactGrade() {
        let haaland: [String: Double] = ["appearances": 35, "goals": 36, "assists": 8]
        let g = ScoringRule.preset("soccer_attacker_fantasy")!
            .grade(stats: haaland, sport: .soccer, position: "FW", seasonYear: 2023)
        XCTAssertEqual(g, 239.0, accuracy: 0.001)
    }

    func testSoccerDefenderExactGrade() {
        let keeper: [String: Double] = ["appearances": 38, "goals": 0, "assists": 0, "clean_sheets": 24]
        let g = ScoringRule.preset("soccer_defender_fantasy")!
            .grade(stats: keeper, sport: .soccer, position: "GK", seasonYear: 2005)
        XCTAssertEqual(g, 115.0, accuracy: 0.001)
    }

    func testTennisExactGrade() {
        let djokovic2015: [String: Double] = ["matches_won": 82, "matches_lost": 6,
                                              "titles": 11, "grand_slams": 3]
        let g = ScoringRule.preset("tennis_fantasy")!
            .grade(stats: djokovic2015, sport: .tennis, position: "Player", seasonYear: 2015)
        XCTAssertEqual(g, 257.0, accuracy: 0.001)
    }

    func testTennisGrandSlamsDominateTheTotal() {
        let rule = ScoringRule.preset("tennis_fantasy")!
        let slamSeason: [String: Double] = ["matches_won": 55, "matches_lost": 8, "titles": 5, "grand_slams": 3]
        let grindSeason: [String: Double] = ["matches_won": 70, "matches_lost": 20, "titles": 3, "grand_slams": 0]
        XCTAssertGreaterThan(
            rule.grade(stats: slamSeason, sport: .tennis, position: "Player", seasonYear: 2015),
            rule.grade(stats: grindSeason, sport: .tennis, position: "Player", seasonYear: 2015))
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
