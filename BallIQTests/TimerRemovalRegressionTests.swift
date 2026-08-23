import XCTest
import SwiftUI
@testable import BallIQ

/// M25's rule, pinned at the level nothing else in this test target guards: **a clock may grade
/// a run, never end one.** `SpeedMultiplierTests` (bottom of `JourneymanTests.swift`) already
/// pins the formula itself; this pins the guarantee the formula exists to serve — that no
/// duelable format, fed through the real scoring call site, can have its result zeroed,
/// downgraded, or floored below its raw score for lateness, and that the clocks which
/// legitimately still expire (a duel's 24h scheduling window, the hand-off display) are wired to
/// nothing that could gate a score.
///
/// Server-side lateness fail-states (`submit_versus_result`, `submit_versus_live_result`) are
/// Postgres, not Swift, and out of this stream's ownership — not re-verified here.
final class TimerRemovalRegressionTests: XCTestCase {

    // MARK: - No format's score can be zeroed or downgraded for lateness

    /// Every timed format, finished a full day past its own par rather than a few seconds over
    /// — if a penalty branch ever crept back into `SpeedMultiplier.points` (the one call site
    /// `RepositoryContainer.recordGameResult` uses for every format), this is where it would
    /// show up, because it is exercised through the exact same call the app makes.
    func testEveryTimedFormatStillScoresRawPointsArbitrarilyPastPar() {
        let started = Date(timeIntervalSince1970: 0)
        let aDayLate = started.addingTimeInterval(86_400)
        for kind: GameFormatKind in [.keep4Normal, .keep4Hard, .whoAmI, .journeyman, .grid] {
            let credited = SpeedMultiplier.points(600, startedAt: started, finishedAt: aDayLate,
                                                  kind: kind)
            XCTAssertEqual(credited, 600, "\(kind) paid less than its raw score for finishing a "
                           + "day late — that is the zero/downgrade fail-state M25 removed")
        }
    }

    /// Over/Under and Draft & Spin never had a clock. Routed through the same call path a timed
    /// format uses, they must come back untouched regardless of how much wall time passed —
    /// proving the "arcade formats are exempt" rule survives contact with the real call site, not
    /// just `SpeedMultiplier.par`'s own nil check (already pinned in isolation by
    /// `testArcadeFormatsAreNotTimeSensitive`).
    func testArcadeFormatsNeverGainATimePenaltyThroughTheRealCallSite() {
        let started = Date(timeIntervalSince1970: 0)
        for elapsed: TimeInterval in [0, 1, 86_400] {
            for kind: GameFormatKind in [.overUnder, .draftSpin] {
                let credited = SpeedMultiplier.points(400, startedAt: started,
                                                       finishedAt: started.addingTimeInterval(elapsed),
                                                       kind: kind)
                XCTAssertEqual(credited, 400)
            }
        }
    }

    /// The property that makes it safe to have applied this everywhere at once: `adjusted` has
    /// no branch, anywhere in its input space, that pays less than the raw score. Swept broadly
    /// (negative elapsed, elapsed far beyond any real par, zero score) rather than at a few hand
    /// picked points, because a penalty branch reappearing even at one boundary would recreate
    /// the timer as a fail-state under a different name.
    func testAdjustedNeverPaysLessThanRawScoreAcrossTheInputSpace() {
        let scores: [Double] = [0, 1, 50, 400, 1000]
        let pars: [TimeInterval] = [1, 60, 120, 180]
        let fractionsOfPar: [Double] = [-0.5, 0, 0.001, 0.25, 0.5, 0.75, 0.999, 1.0, 1.5, 100]
        for score in scores {
            for par in pars {
                for fraction in fractionsOfPar {
                    let elapsed = par * fraction
                    let adjusted = SpeedMultiplier.adjusted(score: score, elapsed: elapsed, par: par)
                    XCTAssertGreaterThanOrEqual(adjusted, score - 1e-9,
                        "score \(score) elapsed \(elapsed) par \(par) paid \(adjusted) — below its "
                        + "own raw score")
                }
            }
        }
    }

    // MARK: - Scheduling/hand-off clocks are not wired into scoring

    /// `DuelSession.isExpired`/`secondsLeft` back the 24h scheduling window and the live-duel
    /// hand-off display — not gameplay. A session that reads as long expired must still credit a
    /// board finished at that same instant its full speed-adjusted score, because
    /// `SpeedMultiplier` only ever reads `startedAt`/`finishedAt` against a format's `par` — it
    /// has no dependency on `DuelSession` at all, and this pins that nobody introduces one.
    func testAnExpiredDuelSessionDoesNotGateSpeedMultiplierScoring() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let session = DuelSession(challengeID: 1, format: .keep4, boardID: "p1",
                                  opponentUserID: nil, opponentName: nil,
                                  secondsRemaining: 5, capturedAt: started)
        let longAfter = started.addingTimeInterval(10_000)
        XCTAssertTrue(session.isExpired(at: longAfter),
                      "test setup is broken if this session doesn't actually read as expired")
        let credited = SpeedMultiplier.points(1000, startedAt: started, finishedAt: longAfter,
                                              kind: .keep4Normal)
        XCTAssertEqual(credited, 1000, "a DuelSession reading as expired must never gate or "
                       + "reduce what a finished run is worth")
    }

    /// `DuelStatusBar`'s own doc comment: "This used to be a countdown, and M25 removed the
    /// clock from it entirely." Its initializer takes only the session and the player's own live
    /// tally — no expiry callback, no "on timeout" closure. Building it with exactly that
    /// argument list is the compile-time half of the pin the brief asks for: a future edit that
    /// re-added a *required* force-finish callback would fail this file's build rather than wait
    /// for a runtime assertion to notice.
    @MainActor
    func testDuelStatusBarTakesNoExpiryCallback() {
        let session = DuelSession(challengeID: 1, format: .keep4, boardID: "p1",
                                  opponentUserID: nil, opponentName: nil, secondsRemaining: 5,
                                  capturedAt: Date(timeIntervalSince1970: 0))
        _ = DuelStatusBar(session: session)
        _ = DuelStatusBar(session: session, playerScore: 3)
    }
}
