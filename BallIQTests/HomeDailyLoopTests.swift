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

    // MARK: - nextUTCMidnight

    func testNextUTCMidnightRollsOverAtBoundary() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 12
        components.hour = 23; components.minute = 59; components.second = 30
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: components)!

        let target = HomeDailyLoop.nextUTCMidnight(after: now)
        let targetComponents = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
        XCTAssertEqual(targetComponents.year, 2026)
        XCTAssertEqual(targetComponents.month, 7)
        XCTAssertEqual(targetComponents.day, 13)
        XCTAssertEqual(targetComponents.hour, 0)
        XCTAssertEqual(targetComponents.minute, 0)
        XCTAssertEqual(targetComponents.second, 0)
    }

    /// The boundary target is always in the future relative to `now`, even seconds after
    /// midnight UTC — otherwise the countdown would read 23:59:59 for a full day.
    func testNextUTCMidnightJustAfterRolloverTargetsTomorrow() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 13
        components.hour = 0; components.minute = 0; components.second = 5
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: components)!

        let target = HomeDailyLoop.nextUTCMidnight(after: now)
        let targetComponents = utc.dateComponents([.day], from: target)
        XCTAssertEqual(targetComponents.day, 14)
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
}
