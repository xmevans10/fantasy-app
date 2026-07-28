import XCTest
@testable import BallIQ

/// Tests for the pure logic behind Home's post-completion "come back tomorrow" state
/// (backlog #2) — the UTC-midnight countdown target and the "both dailies done" rule.
final class HomeDailyLoopTests: XCTestCase {

    // MARK: - bothDailiesComplete

    func testBothCompleteWhenBothTrue() {
        XCTAssertTrue(HomeDailyLoop.bothDailiesComplete(keep4Completed: true, whoAmICompleted: true))
    }

    func testNotBothCompleteWhenOnlyOneDone() {
        XCTAssertFalse(HomeDailyLoop.bothDailiesComplete(keep4Completed: true, whoAmICompleted: false))
        XCTAssertFalse(HomeDailyLoop.bothDailiesComplete(keep4Completed: false, whoAmICompleted: true))
    }

    /// A puzzle that failed to load reports `nil`, not `false` — must not be treated as done.
    func testFailedLoadIsNotTreatedAsComplete() {
        XCTAssertFalse(HomeDailyLoop.bothDailiesComplete(keep4Completed: nil, whoAmICompleted: true))
        XCTAssertFalse(HomeDailyLoop.bothDailiesComplete(keep4Completed: true, whoAmICompleted: nil))
        XCTAssertFalse(HomeDailyLoop.bothDailiesComplete(keep4Completed: nil, whoAmICompleted: nil))
    }

    // MARK: - nextMidnight

    private func calendar(_ timeZoneID: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneID)!
        return cal
    }

    func testNextMidnightRollsOverAtBoundary() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 12
        components.hour = 23; components.minute = 59; components.second = 30
        let cal = calendar("America/New_York")
        let now = cal.date(from: components)!

        let target = HomeDailyLoop.nextMidnight(after: now, calendar: cal)
        let targetComponents = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
        XCTAssertEqual(targetComponents.year, 2026)
        XCTAssertEqual(targetComponents.month, 7)
        XCTAssertEqual(targetComponents.day, 13)
        XCTAssertEqual(targetComponents.hour, 0)
        XCTAssertEqual(targetComponents.minute, 0)
        XCTAssertEqual(targetComponents.second, 0)
    }

    /// The boundary target is always in the future relative to `now`, even seconds after
    /// midnight — otherwise the countdown would read 23:59:59 for a full day.
    func testNextMidnightJustAfterRolloverTargetsTomorrow() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 13
        components.hour = 0; components.minute = 0; components.second = 5
        let cal = calendar("America/New_York")
        let now = cal.date(from: components)!

        let target = HomeDailyLoop.nextMidnight(after: now, calendar: cal)
        let targetComponents = cal.dateComponents([.day], from: target)
        XCTAssertEqual(targetComponents.day, 14)
    }

    /// The boundary is the *device's* midnight, whatever the timezone — the same instant must
    /// map to different countdown targets in different zones (this is the whole point of the
    /// local-day rollover: a US-evening 5pm content flip was the old UTC behavior).
    func testNextMidnightIsTimezoneLocal() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 12
        components.hour = 22; components.minute = 0; components.second = 0
        let tokyo = calendar("Asia/Tokyo")
        let now = tokyo.date(from: components)!   // one instant…

        let tokyoTarget = HomeDailyLoop.nextMidnight(after: now, calendar: tokyo)
        let nyTarget = HomeDailyLoop.nextMidnight(after: now, calendar: calendar("America/New_York"))
        XCTAssertNotEqual(tokyoTarget, nyTarget, "…must yield a different midnight per zone")
        // Tokyo is 2 hours from its midnight at 22:00 local.
        XCTAssertEqual(tokyoTarget.timeIntervalSince(now), 2 * 3600, accuracy: 1)
    }

    // MARK: - countdownString

    func testCountdownStringFormatsHoursMinutesSeconds() {
        let now = Date(timeIntervalSince1970: 0)
        let target = now.addingTimeInterval(3 * 3600 + 5 * 60 + 9)
        XCTAssertEqual(HomeDailyLoop.countdownString(now: now, target: target), "03:05:09")
    }

    func testCountdownStringClampsAtZeroPastTarget() {
        let now = Date(timeIntervalSince1970: 100)
        let target = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(HomeDailyLoop.countdownString(now: now, target: target), "00:00:00")
    }

    // MARK: - streakFraming

    func testStreakFramingProtectsExistingStreak() {
        XCTAssertEqual(HomeDailyLoop.streakFraming(streak: 5),
                       "Come back tomorrow to protect your 5-day streak")
    }

    func testStreakFramingWithZeroStreakDoesNotClaimAStreakExists() {
        let framing = HomeDailyLoop.streakFraming(streak: 0)
        XCTAssertFalse(framing.contains("0-day"))
        XCTAssertEqual(framing, "Come back tomorrow to start your streak")
    }

    // MARK: - streakLabel

    /// The first line a brand-new install renders. "0 day streak" is a scoreboard of nothing;
    /// zero is the one value that has to read as an invitation.
    func testStreakLabelOnAFreshInstallInvitesInsteadOfCountingZero() {
        let label = HomeDailyLoop.streakLabel(streak: 0)
        XCTAssertFalse(label.contains("0"))
        XCTAssertEqual(label, "Play today to start a streak")
    }

    func testStreakLabelIsSingularAtOneDay() {
        XCTAssertEqual(HomeDailyLoop.streakLabel(streak: 1), "1 day streak")
        XCTAssertEqual(HomeDailyLoop.streakLabel(streak: 12), "12 day streak")
    }
}
