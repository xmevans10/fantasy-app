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
        _ = await repo.recordCompletion(format: .keep4Normal, puzzleID: "keep4-a", awardingXP: 100, date: Date())
        let snap = await repo.load()
        XCTAssertTrue(snap.hasCompletedToday(puzzleID: "keep4-a"))
        XCTAssertFalse(snap.hasCompletedToday(puzzleID: "whoami-b"))
    }

    func testKeep4HardAndNormalBothMarkTheSamePuzzleID() async {
        _ = await repo.recordCompletion(format: .keep4Hard, puzzleID: "keep4-a", awardingXP: 150, date: Date())
        let snap = await repo.load()
        XCTAssertTrue(snap.hasCompletedToday(puzzleID: "keep4-a"))
    }

    func testCompletedPuzzlesResetOnNewDay() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        _ = await repo.recordCompletion(format: .keep4Normal, puzzleID: "keep4-a", awardingXP: 100, date: yesterday)
        let snap = await repo.load()
        XCTAssertFalse(snap.hasCompletedToday(puzzleID: "keep4-a"))
        XCTAssertTrue(snap.completedPuzzleIDsToday.isEmpty)
    }

    func testStreakAdvancesOnceRegardlessOfHowManyFormatsPlayedSameDay() async {
        let today = Date()
        _ = await repo.recordCompletion(format: .keep4Normal, puzzleID: "keep4-a", awardingXP: 100, date: today)
        let second = await repo.recordCompletion(format: .whoAmI, puzzleID: "whoami-b", awardingXP: 100, date: today)
        XCTAssertEqual(second.streak, 1)
        XCTAssertTrue(second.hasCompletedToday(puzzleID: "keep4-a"))
        XCTAssertTrue(second.hasCompletedToday(puzzleID: "whoami-b"))
    }

    func testOverwriteDoesNotClearPerCardCompletion() async {
        _ = await repo.recordCompletion(format: .keep4Normal, puzzleID: "keep4-a", awardingXP: 100, date: Date())
        // Simulates a server-authoritative sync pull, which has no opinion on per-card completion.
        repo.overwrite(ProgressSnapshot(streak: 5, xp: 500, lastPlayedDay: LocalProgressRepository.dayString(Date())))
        let snap = await repo.load()
        XCTAssertTrue(snap.hasCompletedToday(puzzleID: "keep4-a"))
        XCTAssertEqual(snap.streak, 5)
        XCTAssertEqual(snap.xp, 500)
    }

    /// Regression: completing "today's" keep4 puzzle must not falsely show DONE for a
    /// *different* puzzle later served under the same daily slot (e.g. content regenerated
    /// mid-day) — completion has to be keyed by the specific puzzle id, not just the format.
    func testCompletingOldPuzzleDoesNotMarkADifferentPuzzleWithSameFormatComplete() async {
        _ = await repo.recordCompletion(format: .keep4Normal, puzzleID: "keep4-yesterdays-content",
                                        awardingXP: 100, date: Date())
        let snap = await repo.load()
        XCTAssertFalse(snap.hasCompletedToday(puzzleID: "keep4-todays-new-content"))
    }
}
