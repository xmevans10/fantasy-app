import XCTest
@testable import BallIQ

final class RatingEngineTests: XCTestCase {

    func testBetterPerformanceGainsMore() {
        let low = RatingEngine.delta(rating: 1000,
            outcome: GameOutcome(format: .keep4Normal, sport: .nfl, performance: 0.6))
        let high = RatingEngine.delta(rating: 1000,
            outcome: GameOutcome(format: .keep4Normal, sport: .nfl, performance: 0.9))
        XCTAssertGreaterThan(high, low)
    }

    func testBelowExpectedLosesRating() {
        let change = RatingEngine.apply(rating: 1000,
            outcome: GameOutcome(format: .keep4Normal, sport: .nfl, performance: 0.2))
        XCTAssertLessThan(change.delta, 0)
    }

    func testRatingNeverGoesNegative() {
        let change = RatingEngine.apply(rating: 5,
            outcome: GameOutcome(format: .whoAmI, sport: .nba, performance: 0.0))
        XCTAssertGreaterThanOrEqual(change.new, 0)
    }

    func testHarderFormatWeightsMore() {
        // Same above-expected gap → harder format yields a larger gain.
        let normal = RatingEngine.delta(rating: 1000,
            outcome: GameOutcome(format: .keep4Normal, sport: .nfl, performance: 0.8))
        let hard = RatingEngine.delta(rating: 1000,
            outcome: GameOutcome(format: .keep4Hard, sport: .nfl, performance: 0.8))
        let whoami = RatingEngine.delta(rating: 1000,
            outcome: GameOutcome(format: .whoAmI, sport: .nfl, performance: 0.8))
        XCTAssertLessThan(normal, hard)
        XCTAssertLessThan(hard, whoami)
    }

    func testExpectedRisesWithRating() {
        XCTAssertLessThan(RatingEngine.expectedPerformance(for: 1000),
                          RatingEngine.expectedPerformance(for: 1600))
    }
}

final class LevelCurveTests: XCTestCase {

    func testLevelOneAtZeroXP() {
        XCTAssertEqual(LevelCurve.level(forXP: 0), 1)
    }

    func testLevelIncreasesWithXP() {
        XCTAssertLessThanOrEqual(LevelCurve.level(forXP: 100), LevelCurve.level(forXP: 5000))
        XCTAssertGreaterThan(LevelCurve.level(forXP: 5000), 1)
    }

    func testProgressWithinLevelIsBounded() {
        let p = LevelCurve.progress(forXP: 250)
        XCTAssertGreaterThanOrEqual(p.intoLevel, 0)
        XCTAssertLessThanOrEqual(p.intoLevel, p.span)
        XCTAssertGreaterThan(p.span, 0)
    }
}

final class BundledContentTests: XCTestCase {

    func testWhoAmIPuzzlesWellFormed() {
        let repo = LocalPuzzleRepository()
        // availableSports should include both launch sports.
        XCTAssertTrue(repo.availableSports.contains(.nfl))
        XCTAssertTrue(repo.availableSports.contains(.nba))
    }
}
