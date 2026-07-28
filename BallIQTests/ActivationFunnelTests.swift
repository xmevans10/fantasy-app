import XCTest
import UserNotifications
@testable import BallIQ

/// The activation funnel's arithmetic and its fire-once rules. Everything here runs against an
/// injected `UserDefaults` suite: these tests are *hosted* (they execute inside the real
/// BallIQ.app process), so writing `activation.*` through `.standard` would land in the real app
/// container and make the next manual launch look like a returning install — the same class of
/// pollution `DiskCache.directoryOverride` exists to prevent.
final class ActivationFunnelTests: XCTestCase {

    private let suiteName = "ActivationFunnelTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A fixed calendar so the day arithmetic can't be decided by wherever CI happens to run.
    private func state(_ tz: String = "America/New_York") -> ActivationState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        return ActivationState(defaults: defaults, calendar: calendar)
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: - app_opened

    func testFirstLaunchIsFlaggedAndIsDayZero() {
        let open = state().recordOpen(now: date("2026-07-27T14:00:00Z"))
        XCTAssertEqual(open, ActivationState.AppOpen(firstOpen: true, dayIndex: 0))
        XCTAssertEqual(open.properties, ["first_open": "true", "day_index": "0"])
    }

    func testSecondLaunchSameDayIsNotFirstOpen() {
        let s = state()
        _ = s.recordOpen(now: date("2026-07-27T14:00:00Z"))
        let again = s.recordOpen(now: date("2026-07-27T23:00:00Z"))
        XCTAssertEqual(again, ActivationState.AppOpen(firstOpen: false, dayIndex: 0))
    }

    /// The headline retention number: `day_index == 1` *is* the next-day return, which is why
    /// there's no separate `next_day_return` event (see docs/ANALYTICS.md).
    func testNextDayReturnReadsAsDayOne() {
        let s = state()
        _ = s.recordOpen(now: date("2026-07-27T14:00:00Z"))
        XCTAssertEqual(s.recordOpen(now: date("2026-07-28T09:00:00Z")).dayIndex, 1)
        XCTAssertEqual(s.recordOpen(now: date("2026-08-03T09:00:00Z")).dayIndex, 7)
    }

    /// Day boundaries are the device's local ones, not UTC — `progress.lastPlayedDay` is a local
    /// day string and the streak-risk push fires at local 8pm, so a return measured on UTC days
    /// would disagree with the streak it exists to explain. 8pm New York on the 27th is already
    /// the 28th in UTC; it must still be day 0.
    func testDayIndexUsesLocalDaysNotUTC() {
        let s = state()
        _ = s.recordOpen(now: date("2026-07-28T00:30:00Z"))   // 2026-07-27 20:30 in New York
        XCTAssertEqual(s.recordOpen(now: date("2026-07-28T03:00:00Z")).dayIndex, 0)
        XCTAssertEqual(s.recordOpen(now: date("2026-07-28T14:00:00Z")).dayIndex, 1)
    }

    /// A backwards device clock must not produce a negative bucket nobody queries for.
    func testClockRollbackFloorsAtDayZero() {
        let s = state()
        _ = s.recordOpen(now: date("2026-07-27T14:00:00Z"))
        XCTAssertEqual(s.recordOpen(now: date("2026-07-20T14:00:00Z")).dayIndex, 0)
    }

    // MARK: - Fire-once milestones

    func testMilestoneFiresExactlyOnce() {
        let s = state()
        XCTAssertTrue(s.markOnce(.firstGameCompleted))
        XCTAssertFalse(s.markOnce(.firstGameCompleted))
        XCTAssertTrue(s.has(.firstGameCompleted))
        // Independent keys — finishing a game must not retire the push primer.
        XCTAssertFalse(s.has(.pushPrimerAnswered))
    }

    func testPushPrimerIsOfferedUntilAnswered() {
        let s = state()
        XCTAssertTrue(s.shouldOfferPushPrimer)
        s.markOnce(.pushPrimerAnswered)
        XCTAssertFalse(s.shouldOfferPushPrimer)
    }

    // MARK: - Schema stability

    /// These strings are the funnel's column values and history isn't retroactively renameable,
    /// so a rename has to break a test rather than silently split one funnel into two — the same
    /// rule `AnalyticsClientTests` applies to the purchase funnel.
    func testActivationEventNamesAreStable() {
        XCTAssertEqual(AnalyticsEvent.appOpened.rawValue, "app_opened")
        XCTAssertEqual(AnalyticsEvent.onboardingStepViewed.rawValue, "onboarding_step_viewed")
        XCTAssertEqual(AnalyticsEvent.firstGameStarted.rawValue, "first_game_started")
        XCTAssertEqual(AnalyticsEvent.firstGameCompleted.rawValue, "first_game_completed")
    }

    func testOnboardingStepRawValuesAndOrderAreStable() {
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue),
                       ["sport", "how_to_play", "account"])
    }

    /// Milestone keys are persisted UserDefaults keys, so renaming one silently re-fires the
    /// milestone for every existing install.
    func testMilestoneKeysAreStable() {
        XCTAssertEqual(ActivationState.Milestone.firstGameStarted.rawValue, "activation.firstGameStarted")
        XCTAssertEqual(ActivationState.Milestone.firstGameCompleted.rawValue, "activation.firstGameCompleted")
        XCTAssertEqual(ActivationState.Milestone.pushPrimerAnswered.rawValue, "activation.pushPrimerAnswered")
    }

    func testAuthorizationStatusAnalyticsValues() {
        XCTAssertEqual(UNAuthorizationStatus.notDetermined.analyticsValue, "not_determined")
        XCTAssertEqual(UNAuthorizationStatus.denied.analyticsValue, "denied")
        XCTAssertEqual(UNAuthorizationStatus.authorized.analyticsValue, "authorized")
        XCTAssertEqual(UNAuthorizationStatus.provisional.analyticsValue, "provisional")
    }
}
