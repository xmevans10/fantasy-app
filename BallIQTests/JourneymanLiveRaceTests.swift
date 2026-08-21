import XCTest
@testable import BallIQ

/// `LiveRaceOutcome.decide` is what turns raw server flags into the headline
/// `JourneymanResultView` shows — get it wrong and a player sees "SOLVED" over a defeat, or a
/// consolation "OUT OF GUESSES" over a run the opponent actually ended by being faster. These
/// tests pin every branch purely (no view, no network), including the two race conditions M23
/// §1 calls out by name: two sides believing they solved "at the same instant", and a solve that
/// lands after the server has already closed the duel.
final class JourneymanLiveRaceOutcomeTests: XCTestCase {

    // MARK: - The plain cases

    /// If this regresses, a player who beat their opponent to the answer would see the generic
    /// "SOLVED" instead of a headline that actually says they were first — the whole point of a
    /// *race* result screen versus a plain solo one.
    func testSolvingWhileTheOpponentIsStillActiveReadsAsSolvingFirst() {
        XCTAssertEqual(LiveRaceOutcome.decide(mySolved: true, myFinished: true,
                                              theirSolved: false, theirFinished: false),
                       .wonBySolvingFirst)
    }

    /// The opponent already burned all five guesses (or gave up) before I named the player —
    /// still a win, but "SOLVED FIRST" would overstate a race that wasn't actually live at the
    /// finish, which is why this is its own case rather than folding into the one above.
    func testSolvingAfterTheOpponentHasAlreadyExhaustedReadsDifferentlyFromSolvingFirst() {
        let afterExhausted = LiveRaceOutcome.decide(mySolved: true, myFinished: true,
                                                    theirSolved: false, theirFinished: true)
        XCTAssertEqual(afterExhausted, .wonAfterOpponentExhausted)
        XCTAssertNotEqual(afterExhausted, .wonBySolvingFirst)
    }

    /// The opponent named the player — my board has to report a loss regardless of what my own
    /// guess count or "finished" flag says, because §1's rule is that their solve ends my run
    /// outright, not that it merely outscores whatever I'd done.
    func testTheOpponentSolvingIsALossNoMatterWhatMyOwnFlagsSay() {
        XCTAssertEqual(LiveRaceOutcome.decide(mySolved: false, myFinished: false,
                                              theirSolved: true, theirFinished: true),
                       .lostToOpponentSolve)
        XCTAssertEqual(LiveRaceOutcome.decide(mySolved: false, myFinished: true,
                                              theirSolved: true, theirFinished: false),
                       .lostToOpponentSolve)
    }

    /// Neither side ever named the player before the duel closed — a real, recorded draw
    /// (M23 §1), distinct from "still in progress".
    func testNeitherSideSolvingIsADraw() {
        XCTAssertEqual(LiveRaceOutcome.decide(mySolved: false, myFinished: true,
                                              theirSolved: false, theirFinished: true),
                       .draw)
        // Also a draw even if one side hadn't technically run out yet when the clock hit zero.
        XCTAssertEqual(LiveRaceOutcome.decide(mySolved: false, myFinished: false,
                                              theirSolved: false, theirFinished: true),
                       .draw)
    }

    // MARK: - Simultaneity: "you solve at the same instant they do"

    /// Models the real simultaneous-solve scenario from *both* clients' points of view: two
    /// players submit around the same instant, the server's first-write-wins picks exactly one
    /// winner, and each client's next poll reflects that decision as `me`/`them`. Whichever side
    /// actually won sees a win; the other sees a loss — never both, never neither.
    func testASimultaneousSolveProducesExactlyOneWinnerAcrossBothClients() {
        // From the winner's device: their own poll shows `me.solved`, opponent never solved.
        let winnerSide = LiveRaceOutcome.decide(mySolved: true, myFinished: true,
                                                theirSolved: false, theirFinished: false)
        // From the loser's device: their poll shows the opponent got there, they never did.
        let loserSide = LiveRaceOutcome.decide(mySolved: false, myFinished: true,
                                               theirSolved: true, theirFinished: false)
        XCTAssertEqual(winnerSide, .wonBySolvingFirst)
        XCTAssertEqual(loserSide, .lostToOpponentSolve)
        XCTAssertNotEqual(winnerSide, loserSide)
    }

    /// A pathological/defensive input a real server should never produce (both `solved` flags
    /// true in the same snapshot — a stale poll racing a fresh submit), pinning the tiebreak
    /// itself: the opponent's solve always wins it. Getting this backwards would let a stale
    /// read flash a false "YOU WIN" on a board the server actually recorded as a loss — the one
    /// outcome worse than an overly cautious "you lost".
    func testWhenBothSidesReadSolvedTheOpponentTakesPrecedence() {
        XCTAssertEqual(LiveRaceOutcome.decide(mySolved: true, myFinished: true,
                                              theirSolved: true, theirFinished: true),
                       .lostToOpponentSolve)
    }

    // MARK: - Late solve after the deadline+grace window

    /// M23 §3: a solve arriving after `live_started_at + time_limit_seconds + 10s` scores as
    /// not-solved server-side, not as rejected. From the client's point of view that means the
    /// poll it eventually sees back never sets `me.solved` — this pins that even though the
    /// player locally typed the right name, the *decided* outcome (built from the server's
    /// flags, never the player's own keystroke) does not credit a win they only believe they
    /// earned. If the opponent also never solved, that is a draw; the local "I typed it right"
    /// belief must not leak into the verdict.
    func testALateSolveThatMissedTheGraceWindowNeverCreditsAWin() {
        // Server never set `me.solved`; the duel is closed all the same (deadline passed).
        let outcome = LiveRaceOutcome.decide(mySolved: false, myFinished: true,
                                             theirSolved: false, theirFinished: true)
        XCTAssertEqual(outcome, .draw)
        XCTAssertNotEqual(outcome, .wonBySolvingFirst)
        XCTAssertNotEqual(outcome, .wonAfterOpponentExhausted)
    }
}

/// `JourneymanResultView.liveDuelVerdict` is the seam between a live race's outcome and the
/// shared `DuelVerdict`/`ChallengeResultBanner` vocabulary (AGENTS.md §4: one banner, not a
/// second one just for races) — these pin that the hits it builds always agree with
/// `LiveRaceOutcome.decide` on who actually won, since the banner and the scoreHeader above it
/// would read as contradicting each other otherwise.
final class JourneymanLiveDuelVerdictTests: XCTestCase {

    private func solvedResult(guessesUsed: Int) -> JourneymanScoring.Result {
        JourneymanScoring.score(guessesUsed: guessesUsed, solved: true)
    }
    private func unsolvedResult(guessesUsed: Int) -> JourneymanScoring.Result {
        JourneymanScoring.score(guessesUsed: guessesUsed, solved: false)
    }

    /// A player who named the player on guess 1 (the max possible hits) against an opponent who
    /// never solved must render as a win — anything else would contradict the "SOLVED FIRST"
    /// headline sitting right above the banner.
    func testMySolveWithTheirNoSolveIsAWin() {
        let verdict = JourneymanResultView.liveDuelVerdict(
            opponentName: "rival", myResult: solvedResult(guessesUsed: 1),
            theirGuesses: 3, theirSolved: false)
        XCTAssertEqual(verdict.outcome, .win)
        XCTAssertGreaterThan(verdict.myHits, verdict.theirHits)
    }

    /// The mirror image: I never solved, they did — a loss, whatever guess count they used it
    /// on. `theirHits` still has to reflect *how* efficiently they solved (fewer guesses = more
    /// hits, same conversion the async duel already uses), not just "nonzero".
    func testTheirSolveWithMyNoSolveIsALoss() {
        let verdict = JourneymanResultView.liveDuelVerdict(
            opponentName: "rival", myResult: unsolvedResult(guessesUsed: 5),
            theirGuesses: 1, theirSolved: true)
        XCTAssertEqual(verdict.outcome, .loss)
        XCTAssertEqual(verdict.theirHits, JourneymanScoring.maxGuesses)
        XCTAssertEqual(verdict.myHits, 0)
    }

    /// Nobody solved — a real tie, not a courtesy win the way a ladder bot draw would be
    /// (`tieGoesToPlayer: false` here, unlike `LadderRunSession.verdict`), because a dead heat
    /// between two humans is exactly that.
    func testNeitherSolvingIsATieNotACourtesyWin() {
        let verdict = JourneymanResultView.liveDuelVerdict(
            opponentName: "rival", myResult: unsolvedResult(guessesUsed: 5),
            theirGuesses: 5, theirSolved: false)
        XCTAssertEqual(verdict.outcome, .tie)
    }
}
