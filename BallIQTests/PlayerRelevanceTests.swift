import XCTest
@testable import BallIQ

final class PlayerRelevanceTests: XCTestCase {

    private func season(_ id: String, stats: [String: Double], position: String = "RB") -> CatalogSeason {
        CatalogSeason(id: id, sport: .nfl, name: "Player \(id)", teamAbbr: "SF",
                     seasonYear: 2020, position: position, stats: stats)
    }

    func testFiltersOutLowPowerSeasonsWhenEnoughStrongOnesRemain() {
        let strong = (0..<10).map { season("s\($0)", stats: ["rushing_yards": 1800, "rushing_tds": 20, "ypc": 5.5]) }
        let weak = season("weak", stats: ["rushing_yards": 20, "rushing_tds": 0, "ypc": 1.2])
        let filtered = PlayerRelevance.filter(strong + [weak], sport: .nfl, minimum: 3)
        XCTAssertFalse(filtered.contains { $0.id == "weak" })
        XCTAssertEqual(filtered.count, strong.count)
    }

    /// The exact shape of the bug this guards against: a thin position (e.g. soccer DF, 2 real
    /// rows total this session) must never be filtered down to empty just because every real
    /// candidate happens to be a modest season — same graceful-degradation contract as
    /// `Sport.sliceForPosition`.
    func testFallsBackToFullSetWhenFilteringWouldDropBelowMinimum() {
        let weak = (0..<2).map { season("w\($0)", stats: ["rushing_yards": 20, "rushing_tds": 0, "ypc": 1.2]) }
        let filtered = PlayerRelevance.filter(weak, sport: .nfl, minimum: 3)
        XCTAssertEqual(filtered.count, weak.count)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(PlayerRelevance.filter([], sport: .nfl).isEmpty)
    }
}
