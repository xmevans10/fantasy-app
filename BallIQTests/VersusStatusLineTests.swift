import XCTest
@testable import BallIQ

/// `VersusView`'s pure status copy — forfeit lines must say *who* didn't play, open rows
/// must carry expiry pressure, and the series line must track `versus_series` exactly.
/// Mechanics mirrored: `resolve_versus_challenge` resolves a single no-show to `completed`
/// with one score missing; `forfeited` is reserved for the double no-show.
final class VersusStatusLineTests: XCTestCase {

    private let me = "me-uuid"
    private let them = "them-uuid"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func challenge(status: String, myScore: Double?, theirScore: Double?,
                           winner: String? = nil, hoursToExpiry: Double = 12) -> VersusChallenge {
        VersusChallenge(id: 1, seriesId: 10, sport: .nfl, puzzleId: "p1",
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
                       "They didn't play in time — win by forfeit")
    }

    func testMyForfeitReadsAsForfeitLoss() {
        let c = challenge(status: "completed", myScore: nil, theirScore: 0.7, winner: them)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "Time ran out before you played — forfeit loss")
    }

    func testDoubleNoShowReadsAsNoContest() {
        let c = challenge(status: "forfeited", myScore: nil, theirScore: nil)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "Expired — neither of you played")
    }

    // MARK: - Open rows carry expiry pressure

    func testUnplayedOpenRowShowsPlayPromptWithHoursLeft() {
        let c = challenge(status: "pending", myScore: nil, theirScore: nil, hoursToExpiry: 14.5)
        XCTAssertEqual(VersusView.statusLine(c, me: me, now: now),
                       "Play today's puzzle · 14h left")
    }

    func testPlayedOpenRowShowsWaitingWithHoursLeft() {
        let c = challenge(status: "active", myScore: 0.5, theirScore: nil, hoursToExpiry: 3)
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
                       "Series 2–1 · best of 7")
        XCTAssertEqual(VersusView.seriesLine(series(winsA: 2, winsB: 1, status: "active"), me: them),
                       "Series 1–2 · best of 7")
    }

    func testCompletedSeriesShowsOutcomeFromEachSide() {
        let done = series(winsA: 4, winsB: 3, status: "completed")
        XCTAssertEqual(VersusView.seriesLine(done, me: me), "Series won 4–3")
        XCTAssertEqual(VersusView.seriesLine(done, me: them), "Series lost 3–4")
    }

    // MARK: - Badge count

    func testUnplayedCountIgnoresPlayedAndSettledRows() {
        let rows = [
            VersusChallengeRow(challenge: challenge(status: "pending", myScore: nil, theirScore: nil),
                               opponentUsername: "a"),
            VersusChallengeRow(challenge: challenge(status: "active", myScore: 0.4, theirScore: nil),
                               opponentUsername: "b"),   // played — waiting on them
            VersusChallengeRow(challenge: challenge(status: "completed", myScore: 0.4, theirScore: 0.2, winner: me),
                               opponentUsername: "c"),   // settled
            VersusChallengeRow(challenge: challenge(status: "active", myScore: nil, theirScore: 0.9),
                               opponentUsername: "d"),   // they played, I haven't
        ]
        XCTAssertEqual(VersusChallengeRow.unplayedCount(rows, me: me), 2)
    }
}
