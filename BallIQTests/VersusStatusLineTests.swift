import XCTest
@testable import BallIQ

/// `VersusView`'s pure status copy — forfeit lines must say *who* didn't play, open rows
/// must carry expiry pressure, and the series line must track `versus_series` exactly.
/// Mechanics mirrored: `resolve_versus_challenge` resolves a single no-show to `completed`
/// with one score missing; `forfeited` is reserved for the double no-show; and a `completed`
/// row with no winner is a genuine dead heat (equal scores *and* equal elapsed time), which
/// is a different thing from either.
final class VersusStatusLineTests: XCTestCase {

    private let me = "me-uuid"
    private let them = "them-uuid"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func challenge(status: String, myScore: Double?, theirScore: Double?,
                           winner: String? = nil, hoursToExpiry: Double = 12,
                           format: PuzzleFormat = .keep4) -> VersusChallenge {
        VersusChallenge(id: 1, seriesId: 10, sport: .nfl, format: format, puzzleId: "p1",
                        challengerId: me, opponentId: them, status: status,
                        challengerScore: myScore, opponentScore: theirScore, winnerId: winner,
                        createdAt: now.addingTimeInterval(-3_600),
                        expiresAt: now.addingTimeInterval(hoursToExpiry * 3_600))
    }

    // MARK: - Completed / forfeit lines

    func testCompletedWithBothScoresShowsTheScoreLine() {
        let c = challenge(status: "completed", myScore: 0.8, theirScore: 0.6, winner: me)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now), "You 80 – 60 them")
    }

    func testOpponentForfeitReadsAsWinByForfeit() {
        let c = challenge(status: "completed", myScore: 0.7, theirScore: nil, winner: me)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "They didn't play in time, win by forfeit")
    }

    func testMyForfeitReadsAsForfeitLoss() {
        let c = challenge(status: "completed", myScore: nil, theirScore: 0.7, winner: them)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "Time ran out before you played, forfeit loss")
    }

    func testDoubleNoShowReadsAsNoContest() {
        let c = challenge(status: "forfeited", myScore: nil, theirScore: nil)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "Expired, neither of you played")
    }

    /// A settled duel with no winner is a draw, not "still going" and not a forfeit. Reachable
    /// only when both scores AND both elapsed times are identical, which is why the copy names
    /// the tiebreak that failed to separate them.
    func testDeadHeatReadsAsADraw() {
        let c = challenge(status: "completed", myScore: 0.75, theirScore: 0.75, winner: nil)
        XCTAssertTrue(c.isDraw)
        XCTAssertNil(c.won(me: me))
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "Dead heat, 75 each, to the second")
    }

    func testForfeitedIsNotADraw() {
        // Both are `winner_id is null`; only the `completed` one is a draw.
        XCTAssertFalse(challenge(status: "forfeited", myScore: nil, theirScore: nil).isDraw)
    }

    // MARK: - Open rows carry expiry pressure

    /// An unplayed open row names the game and the sport, not "today's puzzle": duel boards
    /// come from the archive now, so a duel is very often not on today's board at all.
    func testUnplayedOpenRowNamesTheGameAndSportWithHoursLeft() {
        let c = challenge(status: "pending", myScore: nil, theirScore: nil,
                          hoursToExpiry: 14.5, format: .grid)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "The Grid · NFL · 14h left")
    }

    func testPlayedOpenRowShowsWaitingWithHoursLeft() {
        let c = challenge(status: "pending", myScore: 0.5, theirScore: nil, hoursToExpiry: 3)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "Waiting for them to play · 3h left")
    }

    func testSubHourExpiryShowsMinutes() {
        XCTAssertEqual(VersusView.timeLeftText(until: now.addingTimeInterval(45 * 60), now: now),
                       "45m left")
    }

    func testPastDueExpiryShowsExpiring() {
        // The forfeit cron sweeps every 15 minutes, so a past-due open row can render briefly.
        XCTAssertEqual(VersusView.timeLeftText(until: now.addingTimeInterval(-60), now: now),
                       "Expiring…")
    }

    // MARK: - Series line

    private func series(winsA: Int, winsB: Int, status: String) -> VersusSeries {
        // `user_a < user_b` ordering is enforced server-side; here "me" is user_a.
        VersusSeries(id: 10, userA: me, userB: them, sport: .nfl,
                     winsA: winsA, winsB: winsB, status: status)
    }

    func testFreshSeriesShowsNothing() {
        XCTAssertNil(VersusView.seriesLine(series(winsA: 0, winsB: 0, status: "active"), me: me))
    }

    func testRunningSeriesShowsLiveCount() {
        XCTAssertEqual(VersusView.seriesLine(series(winsA: 2, winsB: 1, status: "active"), me: me),
                       "Series 2–1 · first to 4")
        XCTAssertEqual(VersusView.seriesLine(series(winsA: 2, winsB: 1, status: "active"), me: them),
                       "Series 1–2 · first to 4")
    }

    func testCompletedSeriesShowsOutcomeFromEachSide() {
        let done = series(winsA: 4, winsB: 1, status: "completed")
        XCTAssertEqual(VersusView.seriesLine(done, me: me), "Series won 4–1")
        XCTAssertEqual(VersusView.seriesLine(done, me: them), "Series lost 1–4")
    }

    // MARK: - Badge count

    func testUnplayedCountIgnoresPlayedAndSettledRows() {
        let rows = [
            VersusChallengeRow(challenge: challenge(status: "pending", myScore: nil, theirScore: nil),
                               opponentUsername: "a"),
            VersusChallengeRow(challenge: challenge(status: "pending", myScore: 0.4, theirScore: nil),
                               opponentUsername: "b"),   // played — waiting on them
            VersusChallengeRow(challenge: challenge(status: "completed", myScore: 0.4, theirScore: 0.2, winner: me),
                               opponentUsername: "c"),   // settled
            VersusChallengeRow(challenge: challenge(status: "pending", myScore: nil, theirScore: 0.9),
                               opponentUsername: "d"),   // they played, I haven't
        ]
        XCTAssertEqual(VersusChallengeRow.unplayedCount(rows, me: me), 2)
    }

    /// `'active'` is gone from the status domain server-side (a check constraint now forbids
    /// it), but a row cached by an older build could still carry it. It must not be counted as
    /// an open duel, or the tab badge would show a number the list can't explain.
    func testUnplayedCountIgnoresTheRetiredActiveStatus() {
        let rows = [VersusChallengeRow(
            challenge: challenge(status: "active", myScore: nil, theirScore: nil),
            opponentUsername: "legacy")]
        XCTAssertEqual(VersusChallengeRow.unplayedCount(rows, me: me), 0)
    }

    // MARK: - The duel clock

    func testClockTextIsAlwaysMinutesAndSeconds() {
        XCTAssertEqual(DuelSession.clockText(120), "2:00")
        XCTAssertEqual(DuelSession.clockText(105), "1:45")
        XCTAssertEqual(DuelSession.clockText(9), "0:09")
        XCTAssertEqual(DuelSession.clockText(0), "0:00")
        // A negative remainder is reachable if a redraw lands after the deadline.
        XCTAssertEqual(DuelSession.clockText(-5), "0:00")
    }

    /// `expired` is still a question you can ask a session — it is no longer something that
    /// happens *to* a run (M25b). This pins the arithmetic that `TimerRemovalRegressionTests`
    /// then leans on to prove expiry is inert; the old countdown assertions went with
    /// `secondsLeft`, which was deleted because nothing called it.
    func testExpiryIsMeasuredFromACapturedInstantNotATickingTimer() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let session = DuelSession(challengeID: 1, format: .keep4, boardID: "p1",
                                  opponentUserID: nil, opponentName: nil,
                                  secondsRemaining: 90, capturedAt: started)
        XCTAssertFalse(session.isExpired(at: started.addingTimeInterval(89)))
        XCTAssertTrue(session.isExpired(at: started.addingTimeInterval(500)),
                      "time spent backgrounded is still time elapsed")
    }
}
