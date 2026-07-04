import XCTest
@testable import BallIQ

/// "This Week" trending order (M13). Pure — counts come from the `weekly_play_counts`
/// RPC in production; here they're literals.
final class TrendingSortTests: XCTestCase {

    private func summary(_ id: String, createdAt: String) -> CommunitySummary {
        CommunitySummary(id: id, authorId: "author", sport: .nfl, format: "keep4",
                         title: "Title \(id)", playCount: 0, createdAt: createdAt,
                         description: nil, scoring: nil, grain: nil, visibility: nil)
    }

    func testMostWeeklyPlaysFirst() {
        let items = [summary("old-hot", createdAt: "2026-04-01T00:00:00Z"),
                     summary("new-quiet", createdAt: "2026-07-01T00:00:00Z")]
        let sorted = CommunityTrending.sorted(items: items, weeklyPlays: ["old-hot": 5])
        XCTAssertEqual(sorted.map(\.id), ["old-hot", "new-quiet"])
    }

    func testTieBreaksNewestFirst() {
        let items = [summary("a", createdAt: "2026-06-01T00:00:00Z"),
                     summary("b", createdAt: "2026-07-01T00:00:00Z")]
        let sorted = CommunityTrending.sorted(items: items, weeklyPlays: ["a": 3, "b": 3])
        XCTAssertEqual(sorted.map(\.id), ["b", "a"])
    }

    func testZeroCountTailStaysRecentOrdered() {
        let items = [summary("quiet-new", createdAt: "2026-07-01T00:00:00Z"),
                     summary("quiet-old", createdAt: "2026-05-01T00:00:00Z"),
                     summary("hot", createdAt: "2026-01-01T00:00:00Z")]
        let sorted = CommunityTrending.sorted(items: items, weeklyPlays: ["hot": 1])
        XCTAssertEqual(sorted.map(\.id), ["hot", "quiet-new", "quiet-old"])
    }

    func testEmptyCountsDegradesToRecentOrder() {
        // The RPC-not-deployed fallback: no counts at all must reproduce recent order.
        let items = [summary("b", createdAt: "2026-07-01T00:00:00Z"),
                     summary("a", createdAt: "2026-06-01T00:00:00Z"),
                     summary("c", createdAt: "2026-06-15T00:00:00Z")]
        let sorted = CommunityTrending.sorted(items: items, weeklyPlays: [:])
        XCTAssertEqual(sorted.map(\.id), ["b", "c", "a"])
    }
}
