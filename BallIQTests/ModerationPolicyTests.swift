import XCTest
@testable import BallIQ

/// Report-threshold + review-queue grouping logic (M12). Pure — mirrors the server trigger
/// `auto_hide_reported_puzzle` in supabase/schema.sql; same network-free pattern as
/// `CommunityFeedTests`.
final class ModerationPolicyTests: XCTestCase {

    private func report(_ puzzle: String, by reporter: String, reason: String? = nil,
                        at date: String = "2026-07-01T00:00:00Z") -> CommunityReport {
        CommunityReport(puzzleId: puzzle, reporterId: reporter, reason: reason, createdAt: date)
    }

    // MARK: - Threshold

    func testUnderThresholdStaysVisible() {
        XCTAssertFalse(ModerationPolicy.shouldAutoHide(distinctReporters: 0))
        XCTAssertFalse(ModerationPolicy.shouldAutoHide(distinctReporters: 2))
    }

    func testThresholdAndAboveHides() {
        XCTAssertTrue(ModerationPolicy.shouldAutoHide(distinctReporters: 3))
        XCTAssertTrue(ModerationPolicy.shouldAutoHide(distinctReporters: 10))
    }

    // MARK: - Review-case grouping

    func testEachReporterCountsOnce() {
        // Same user reporting twice must not cross the threshold alone —
        // mirrors the trigger's count(DISTINCT reporter_id).
        let reports = [report("p1", by: "u1"), report("p1", by: "u1"), report("p1", by: "u2")]
        let cases = ModerationPolicy.reviewCases(from: reports)
        XCTAssertEqual(cases.count, 1)
        XCTAssertEqual(cases[0].distinctReporters, 2)
        XCTAssertFalse(cases[0].meetsThreshold)
    }

    func testCaseAtThresholdIsFlagged() {
        let reports = (1...3).map { report("p1", by: "u\($0)") }
        XCTAssertTrue(ModerationPolicy.reviewCases(from: reports)[0].meetsThreshold)
    }

    func testMostReportedFirstThenNewest() {
        let reports = [
            report("light", by: "u1", at: "2026-07-02T00:00:00Z"),
            report("heavy", by: "u1", at: "2026-06-01T00:00:00Z"),
            report("heavy", by: "u2", at: "2026-06-02T00:00:00Z"),
            report("recent", by: "u9", at: "2026-07-03T00:00:00Z"),
        ]
        let ids = ModerationPolicy.reviewCases(from: reports).map(\.puzzleId)
        // "heavy" (2 reporters) outranks both singles; the singles tie-break newest-first.
        XCTAssertEqual(ids, ["heavy", "recent", "light"])
    }

    func testReasonsDedupedNewestFirst() {
        let reports = [
            report("p1", by: "u1", reason: "spam", at: "2026-07-01T00:00:00Z"),
            report("p1", by: "u2", reason: "Spam", at: "2026-07-02T00:00:00Z"),
            report("p1", by: "u3", reason: "offensive", at: "2026-07-03T00:00:00Z"),
            report("p1", by: "u4", reason: nil, at: "2026-07-04T00:00:00Z"),
        ]
        let reasons = ModerationPolicy.reviewCases(from: reports)[0].reasons
        // Case-insensitive dedupe keeps the newest spelling; nil reasons drop out.
        XCTAssertEqual(reasons, ["offensive", "Spam"])
    }

    func testLatestReportTimestampWins() {
        let reports = [
            report("p1", by: "u1", at: "2026-07-01T00:00:00Z"),
            report("p1", by: "u2", at: "2026-07-04T00:00:00Z"),
            report("p1", by: "u3", at: "2026-07-02T00:00:00Z"),
        ]
        XCTAssertEqual(ModerationPolicy.reviewCases(from: reports)[0].latestReportAt,
                       "2026-07-04T00:00:00Z")
    }
}
