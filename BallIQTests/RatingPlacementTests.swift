import XCTest
@testable import BallIQ

/// The placement window: a new player's first three **rated** boards do not move their rating.
///
/// Deliberately pure — nothing here builds a `RepositoryContainer` or calls `complete(...)`.
/// These tests are *hosted*, so they run inside the real app process against the real
/// Application Support directory and the real `UserDefaults`; a test that played games through
/// the container would write real rating, real progress and real career-log rows into the
/// simulator and corrupt the next manual launch. That is the same trap
/// `LocalGameLogRepository.directoryOverride` and `ActivationState(defaults:)` exist for. The
/// rule lives in `RatingPlacement` precisely so it can be proved without any of that.
final class RatingPlacementTests: XCTestCase {

    // MARK: - The window opens

    func testTheFirstThreeRatedBoardsDoNotMoveTheRating() {
        for played in 0..<RatingPlacement.games {
            XCTAssertFalse(RatingPlacement.appliesRating(ranked: true, ratedGamesBefore: played),
                           "rated board #\(played + 1) must not move the rating")
        }
    }

    func testTheFourthRatedBoardMovesTheRating() {
        XCTAssertTrue(RatingPlacement.appliesRating(ranked: true,
                                                    ratedGamesBefore: RatingPlacement.games))
    }

    // MARK: - 🔴 The window terminates

    /// **The trap this file exists for.**
    ///
    /// The counter reads `GameResult.ranked`. If the gate also *wrote* that field — stamping rows
    /// with `appliesRating` instead of the caller's `ranked` for consistency with the three
    /// rating gates — the count could only ever be incremented by a row the gate refuses to
    /// create. It would sit at zero forever, placement would never end, and the rating would stop
    /// moving for every player, permanently.
    ///
    /// This simulates the actual feedback loop rather than asserting on one call: play rated
    /// boards, record each row the way `complete()` records it, and count the way the container
    /// counts. Every other test here passes under the broken version, because boards 1-3 behave
    /// identically either way — **only continuing past the third distinguishes a working window
    /// from a permanent one.**
    func testTheWindowTerminates() {
        var log: [Bool] = []          // each entry is a row's recorded `ranked`
        var everApplied = false

        for board in 1...10 {
            let ratedSoFar = log.filter { $0 }.count
            let applies = RatingPlacement.appliesRating(ranked: true, ratedGamesBefore: ratedSoFar)
            if applies { everApplied = true }
            // Exactly what `complete()` writes — the caller's `ranked`, never `applies`.
            log.append(RatingPlacement.recordedRanked(ranked: true))

            if board > RatingPlacement.games {
                XCTAssertTrue(applies,
                              "board \(board) is past placement and must be rated, if this "
                              + "fails, the counter is reading the field the gate writes")
            }
        }
        XCTAssertTrue(everApplied, "the window must close at some point")
        XCTAssertEqual(log.filter { $0 }.count, 10,
                       "every rated board must be recorded as ranked, including placement ones")
    }

    /// The identity above is load-bearing, not decoration: a row played during placement is still
    /// a rated *surface*, and that is what closes the window.
    func testAPlacementRowIsStillRecordedAsRanked() {
        XCTAssertTrue(RatingPlacement.recordedRanked(ranked: true))
        XCTAssertFalse(RatingPlacement.recordedRanked(ranked: false))
    }

    // MARK: - 🔴 Unranked boards never consume a slot

    /// Counting every row rather than only rated ones would let a player who opened Puzzle Blitz
    /// first burn all three protected boards on games that were never going to move their rating.
    func testUnrankedBoardsNeverConsumeASlot() {
        var log: [Bool] = []
        for _ in 1...10 { log.append(RatingPlacement.recordedRanked(ranked: false)) }

        let ratedSoFar = log.filter { $0 }.count
        XCTAssertEqual(ratedSoFar, 0, "ten unranked boards contribute nothing to the count")
        XCTAssertTrue(RatingPlacement.isInPlacement(ratedGames: ratedSoFar))
        XCTAssertEqual(RatingPlacement.remaining(ratedGames: ratedSoFar), RatingPlacement.games)
    }

    /// Placement only ever *removes* rating movement — it never grants it to an unranked board.
    func testPlacementNeverMakesAnUnrankedBoardRated() {
        XCTAssertFalse(RatingPlacement.appliesRating(ranked: false, ratedGamesBefore: 0))
        XCTAssertFalse(RatingPlacement.appliesRating(ranked: false, ratedGamesBefore: 99))
    }

    // MARK: - What the player is shown

    func testRemainingCountsDownAndFloorsAtZero() {
        XCTAssertEqual(RatingPlacement.remaining(ratedGames: 0), 3)
        XCTAssertEqual(RatingPlacement.remaining(ratedGames: 2), 1)
        XCTAssertEqual(RatingPlacement.remaining(ratedGames: 3), 0)
        XCTAssertEqual(RatingPlacement.remaining(ratedGames: 50), 0)
    }

    /// "N of 3" must never read "0 of 3" or "4 of 3" — an unranked board consumes no slot, so the
    /// count the result screen sees can sit outside the window on either side.
    func testTheDisplayedIndexIsClamped() {
        XCTAssertEqual(RatingPlacement.index(ratedGames: 0), 1)
        XCTAssertEqual(RatingPlacement.index(ratedGames: 1), 1)
        XCTAssertEqual(RatingPlacement.index(ratedGames: 3), 3)
        XCTAssertEqual(RatingPlacement.index(ratedGames: 9), 3)
    }

    // MARK: - The premise

    /// The reason the window exists at all: a new account is seated on the *first point* of
    /// Silver, so any loss is a visible demotion. If this ever stops being true, re-examine
    /// whether placement is still the right fix.
    func testANewAccountStartsOnTheFirstPointOfSilver() {
        XCTAssertEqual(Tier.forRating(RatingEngine.startingRating), .silver)
        XCTAssertEqual(Tier.forRating(RatingEngine.startingRating - 1), .bronze,
                       "one point below the starting rating is a different tier")
    }
}
