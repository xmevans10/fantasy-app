import XCTest
@testable import BallIQ

/// Regression tests for the "both Home cards show DONE after playing just one format" bug:
/// per-card completion must be tracked independently of the streak-driving `lastPlayedDay`.
final class ProgressRepositoryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var repo: LocalProgressRepository!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ProgressRepositoryTests")
        defaults.removePersistentDomain(forName: "ProgressRepositoryTests")
        repo = LocalProgressRepository(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ProgressRepositoryTests")
        super.tearDown()
    }

    func testCompletingKeep4DoesNotMarkWhoAmIComplete() async {
        _ = await repo.recordCompletion(format: .keep4Normal, awardingXP: 100, date: Date())
        let snap = await repo.load()
        XCTAssertTrue(snap.hasCompletedToday(.keep4))
        XCTAssertFalse(snap.hasCompletedToday(.whoAmI))
    }

    func testKeep4HardAndNormalBothMarkTheSameCard() async {
        _ = await repo.recordCompletion(format: .keep4Hard, awardingXP: 150, date: Date())
        let snap = await repo.load()
        XCTAssertTrue(snap.hasCompletedToday(.keep4))
    }

    func testCompletedCardsResetOnNewDay() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        _ = await repo.recordCompletion(format: .keep4Normal, awardingXP: 100, date: yesterday)
        let snap = await repo.load()
        XCTAssertFalse(snap.hasCompletedToday(.keep4))
        XCTAssertTrue(snap.completedCardsToday.isEmpty)
    }

    func testStreakAdvancesOnceRegardlessOfHowManyFormatsPlayedSameDay() async {
        let today = Date()
        _ = await repo.recordCompletion(format: .keep4Normal, awardingXP: 100, date: today)
        let second = await repo.recordCompletion(format: .whoAmI, awardingXP: 100, date: today)
        XCTAssertEqual(second.streak, 1)
        XCTAssertTrue(second.hasCompletedToday(.keep4))
        XCTAssertTrue(second.hasCompletedToday(.whoAmI))
    }

    func testOverwriteDoesNotClearPerCardCompletion() async {
        _ = await repo.recordCompletion(format: .keep4Normal, awardingXP: 100, date: Date())
        // Simulates a server-authoritative sync pull, which has no opinion on per-card completion.
        repo.overwrite(ProgressSnapshot(streak: 5, xp: 500, lastPlayedDay: LocalProgressRepository.dayString(Date())))
        let snap = await repo.load()
        XCTAssertTrue(snap.hasCompletedToday(.keep4))
        XCTAssertEqual(snap.streak, 5)
        XCTAssertEqual(snap.xp, 500)
    }
}
