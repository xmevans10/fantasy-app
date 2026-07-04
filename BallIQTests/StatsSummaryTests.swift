import XCTest
@testable import BallIQ

final class StatsSummaryTests: XCTestCase {

    func testEmptyHistoryHasNoGames() {
        let summary = StatsSummary(history: [], currentRating: 1000)
        XCTAssertEqual(summary.gamesPlayed, 0)
        XCTAssertEqual(summary.netChange, 0)
        XCTAssertEqual(summary.best, 1000)
    }

    func testBestPicksHighestPointEvenAfterADrop() {
        let history = [
            RatingPoint(date: Date(timeIntervalSince1970: 0), rating: 1050),
            RatingPoint(date: Date(timeIntervalSince1970: 1), rating: 1120),
            RatingPoint(date: Date(timeIntervalSince1970: 2), rating: 1080),
        ]
        let summary = StatsSummary(history: history, currentRating: 1080)
        XCTAssertEqual(summary.best, 1120)
        XCTAssertEqual(summary.gamesPlayed, 3)
    }

    func testNetChangeMeasuredFromStartingRating() {
        let history = [RatingPoint(date: Date(), rating: 1075)]
        let summary = StatsSummary(history: history, currentRating: 1075)
        XCTAssertEqual(summary.netChange, 1075 - RatingEngine.startingRating)
    }
}
