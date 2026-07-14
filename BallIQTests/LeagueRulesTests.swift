import XCTest
@testable import BallIQ

/// `LeagueRules`' display strings and rollover math — the legend, the countdown card's
/// sub-line, and the How-it-works sheet all read from these, so a regression here would be
/// visible copy drift, not just a wrong number in a test.
final class LeagueRulesTests: XCTestCase {

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func utcDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return Self.utc.date(from: components)!
    }

    // MARK: - Display strings track cutoffs

    func testPromoteAndRelegateLinesMatchCutoffsForFullCohort() {
        XCTAssertEqual(LeagueRules.promoteLine(memberCount: 30), "Top 5 move up")
        XCTAssertEqual(LeagueRules.relegateLine(memberCount: 30), "Bottom 5 move down")
        XCTAssertEqual(LeagueRules.summaryLine(memberCount: 30), "Top 5 move up · Bottom 5 move down")
    }

    /// n=9 is the brief's own honesty check: a cohort too small for the full 5 must say 4,
    /// not silently overclaim "Top 5" the way a hardcoded string would.
    func testPromoteAndRelegateLinesAreHonestForSmallCohort() {
        XCTAssertEqual(LeagueRules.promoteLine(memberCount: 9), "Top 4 move up")
        XCTAssertEqual(LeagueRules.relegateLine(memberCount: 9), "Bottom 4 move down")
    }

    func testLinesDegradeToZeroForTinyCohorts() {
        XCTAssertEqual(LeagueRules.promoteLine(memberCount: 1), "Top 0 move up")
        XCTAssertEqual(LeagueRules.relegateLine(memberCount: 1), "Bottom 0 move down")
    }

    // MARK: - nextRollover

    /// Jan 1, 2024 is a known Monday — anchors every case below without depending on
    /// today's date the way `Date()` would.
    func testRolloverJustBeforeCutoffStaysOnTheSameMonday() {
        let now = utcDate(year: 2024, month: 1, day: 1, hour: 4, minute: 59)
        let next = LeagueRules.nextRollover(after: now)
        let components = Self.utc.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        XCTAssertEqual(components.year, 2024); XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1); XCTAssertEqual(components.hour, 5); XCTAssertEqual(components.minute, 0)
        XCTAssertGreaterThan(next, now)
    }

    func testRolloverJustAfterCutoffJumpsToNextMonday() {
        let now = utcDate(year: 2024, month: 1, day: 1, hour: 5, minute: 1)
        let next = LeagueRules.nextRollover(after: now)
        let components = Self.utc.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        XCTAssertEqual(components.year, 2024); XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 8); XCTAssertEqual(components.hour, 5); XCTAssertEqual(components.minute, 0)
        XCTAssertGreaterThan(next, now)
    }

    func testRolloverFromMidweekTargetsUpcomingMonday() {
        let now = utcDate(year: 2024, month: 1, day: 3, hour: 12) // Wednesday
        let next = LeagueRules.nextRollover(after: now)
        let components = Self.utc.dateComponents([.year, .month, .day, .hour], from: next)
        XCTAssertEqual(components.day, 8); XCTAssertEqual(components.hour, 5)
        XCTAssertGreaterThan(next, now)
    }

    func testRolloverFromSundayTargetsNextDay() {
        let now = utcDate(year: 2023, month: 12, day: 31, hour: 23, minute: 0) // Sunday
        let next = LeagueRules.nextRollover(after: now)
        let components = Self.utc.dateComponents([.year, .month, .day, .hour], from: next)
        XCTAssertEqual(components.year, 2024); XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1); XCTAssertEqual(components.hour, 5)
        XCTAssertGreaterThan(next, now)
    }

    /// Result must always be strictly after the input — a render that lands exactly on the
    /// rollover instant should already be counting toward *next* week, not this one.
    func testRolloverIsAlwaysStrictlyAfterInput() {
        let cases = [
            utcDate(year: 2024, month: 1, day: 1, hour: 5, minute: 0),
            utcDate(year: 2024, month: 1, day: 5, hour: 18, minute: 30),
            utcDate(year: 2024, month: 6, day: 17, hour: 0, minute: 0),
        ]
        for now in cases {
            XCTAssertGreaterThan(LeagueRules.nextRollover(after: now), now)
        }
    }
}
