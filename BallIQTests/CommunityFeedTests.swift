import XCTest
@testable import BallIQ

/// Regression tests for the "community puzzles vanish on refresh" bug: a transient fetch failure
/// must never blank a previously-populated feed.
final class CommunityFeedTests: XCTestCase {

    private func summary(_ id: String) -> CommunitySummary {
        CommunitySummary(id: id, authorId: "author", sport: .nfl, format: "keep4",
                         title: "Title \(id)", playCount: 0, createdAt: "2026-06-29T00:00:00Z",
                         description: nil, scoring: nil, grain: nil, visibility: nil)
    }

    func testFailedFetchKeepsPriorItems() {
        let prior = [summary("p1"), summary("p2")]
        // `feed` throwing surfaces here as `nil` → keep the last good list, don't blank the feed.
        XCTAssertEqual(CommunityView.merge(prior: prior, fetched: nil), prior)
    }

    func testSuccessfulFetchReplacesItems() {
        let prior = [summary("p1")]
        let fresh = [summary("n1"), summary("n2")]
        XCTAssertEqual(CommunityView.merge(prior: prior, fetched: fresh), fresh)
    }

    func testGenuinelyEmptyFetchClearsItems() {
        let prior = [summary("p1")]
        // An empty *success* (no public puzzles for this filter) is a real empty state → replace.
        XCTAssertEqual(CommunityView.merge(prior: prior, fetched: []), [])
    }
}
