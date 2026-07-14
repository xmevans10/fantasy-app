import XCTest
@testable import BallIQ

/// The day's official Daily Draft score must be locked in by the FIRST completion
/// and never overwritten by a later replay, even a luckier one — see `DailyDraftStore`.
final class DailyDraftStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: DailyDraftStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DailyDraftStoreTests")
        defaults.removePersistentDomain(forName: "DailyDraftStoreTests")
        store = DailyDraftStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "DailyDraftStoreTests")
        super.tearDown()
    }

    private func result(points: Int, outcome: DraftSpinResult.Outcome = .madePlayoffs) -> DraftSpinResult {
        DraftSpinResult(wins: 10, losses: 7, totalPoints: points, outcome: outcome)
    }

    func testNoOfficialResultBeforeAnyCompletion() {
        XCTAssertNil(store.officialResult(for: "2026-07-12"))
        XCTAssertFalse(store.hasCompletedDailyDraft(for: "2026-07-12"))
    }

    func testFirstCompletionBecomesOfficial() {
        let recorded = store.recordIfFirst(sport: .nfl, result: result(points: 500), day: "2026-07-12")
        XCTAssertTrue(recorded)
        XCTAssertEqual(store.officialResult(for: "2026-07-12")?.totalPoints, 500)
        XCTAssertTrue(store.hasCompletedDailyDraft(for: "2026-07-12"))
    }

    func testReplayNeverOverwritesTheOfficialScore() {
        _ = store.recordIfFirst(sport: .nfl, result: result(points: 500), day: "2026-07-12")
        // A much better replay attempt still must not become official.
        let recordedAgain = store.recordIfFirst(sport: .nfl, result: result(points: 900, outcome: .champion),
                                                day: "2026-07-12")
        XCTAssertFalse(recordedAgain)
        XCTAssertEqual(store.officialResult(for: "2026-07-12")?.totalPoints, 500)
        XCTAssertEqual(store.officialResult(for: "2026-07-12")?.outcome, DraftSpinResult.Outcome.madePlayoffs.rawValue)
    }

    func testDifferentDaysAreIndependent() {
        _ = store.recordIfFirst(sport: .nfl, result: result(points: 500), day: "2026-07-12")
        XCTAssertNil(store.officialResult(for: "2026-07-13"))
        let recorded = store.recordIfFirst(sport: .nba, result: result(points: 700), day: "2026-07-13")
        XCTAssertTrue(recorded)
        XCTAssertEqual(store.officialResult(for: "2026-07-13")?.sport, "nba")
        XCTAssertEqual(store.officialResult(for: "2026-07-12")?.sport, "nfl")
    }
}
