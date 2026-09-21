import XCTest
@testable import BallIQ

// MARK: - The ladder's speed comparison after M25
//
// The fixture-based curve pin that used to live here (`LadderCurveTests`) was **retired** when the
// ladder moved to Puzzle Blitz. It replayed `tools/ingest/ladder.py`'s per-board model against
// `ladder_rungs.target_win_rate`; that seeder no longer mints any rung the client plays, so the
// pin would have skipped forever on a fresh checkout while still reporting green — the exact
// false-confidence failure its own doc comment warned about. The blitz model is pinned instead by:
//
//   * `BallIQTests/LadderBlitzTests.swift` — the mode/duration/normalisation properties, and
//   * `tools/ingest/tests/test_ladder_blitz.py` — the seeder's pure run/curve model.
//
// `LadderOutcome` itself is still real: the four board modes survive for any rung that is not a
// blitz, and these pin that delegation.

/// `LadderOutcome.adjusted` stopped carrying its own copy of the speed formula and now delegates
/// to `SpeedMultiplier`. These pin what that delegation must not have changed — the ladder is the
/// one place speed still decides a *result* (who won the rung), rather than only points.
final class LadderOutcomeSpeedTests: XCTestCase {

    /// The two must agree exactly. If they drift, a rung's simulated difficulty (solved in
    /// `tools/ingest/ladder.py` against the same formula) stops describing the rung a player
    /// actually meets — the bot would be calibrated for a game nobody is playing.
    func testLadderOutcomeAndSpeedMultiplierAgree() {
        for elapsed in stride(from: 0.0, through: 240.0, by: 20.0) {
            XCTAssertEqual(LadderOutcome.adjusted(score: 0.7, elapsed: elapsed, limit: 120),
                           SpeedMultiplier.adjusted(score: 0.7, elapsed: elapsed, par: 120),
                           accuracy: 1e-12, "diverged at elapsed \(elapsed)")
        }
    }

    /// The property the whole mechanic rests on, asserted where it actually decides a win rather
    /// than only points: a faster run cannot beat a better one.
    func testBeingFasterDoesNotBeatBeingRight() {
        // 0.5 instantly vs 0.75 taking the full par.
        XCTAssertFalse(LadderOutcome.playerWon(playerScore: 0.5, botScore: 0.75,
                                               playerElapsed: 0.1, botElapsed: 120, limit: 120),
                       "a 0.5 finished instantly must not beat a 0.75")
    }

    /// Speed is allowed to separate two players who played the board equally well — that is the
    /// entire reason it survived the timer removal.
    func testAmongEqualScoresTheFasterSideTakesIt() {
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.75, botScore: 0.75,
                                              playerElapsed: 20, botElapsed: 100, limit: 120))
        XCTAssertFalse(LadderOutcome.playerWon(playerScore: 0.75, botScore: 0.75,
                                               playerElapsed: 100, botElapsed: 20, limit: 120))
    }

    /// A rung played with no timing data must still resolve, and must fall back to pure accuracy
    /// with ties going to the player — the documented degradation, and the path an offline or
    /// restored run takes.
    func testWithoutTimingItDegradesToAccuracyWithTiesToThePlayer() {
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.6, botScore: 0.6))
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.61, botScore: 0.6))
        XCTAssertFalse(LadderOutcome.playerWon(playerScore: 0.59, botScore: 0.6))
    }

    /// Taking longer than par is not a loss condition — it only stops paying. A rung must stay
    /// winnable by someone slow who was simply better.
    func testAWinIsStillPossibleArbitrarilyPastPar() {
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.9, botScore: 0.5,
                                              playerElapsed: 6000, botElapsed: 30, limit: 120),
                      "ten minutes late and still clearly better must still win the rung")
    }
}
