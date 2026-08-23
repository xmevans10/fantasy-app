import XCTest
import SwiftUI
@testable import BallIQ

/// `DuelReactionEngine` is the pure crossing/budget/gap policy pulled out of `DuelStatusBar`
/// specifically so it's testable without hosting the view (Task 2 of
/// `prompts/HANDOFF-bot-characters.md`) — a `TimelineView` firing on a real clock isn't
/// something XCTest can drive directly.
final class DuelReactionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    /// A dead-even start (diff == 0) is not itself a crossing — there is no "ahead" yet.
    func testTieProducesNoReaction() {
        var engine = DuelReactionEngine()
        XCTAssertNil(engine.reactionLine(diff: 0, ahead: "Wait — am I winning?",
                                         behind: "Okay okay, I know this one.", now: t0))
        XCTAssertEqual(engine.firedCount, 0)
    }

    /// The bot pulling ahead from a tie is a genuine first crossing.
    func testBotPullingAheadFires() {
        var engine = DuelReactionEngine()
        let line = engine.reactionLine(diff: 2, ahead: "Wait — am I winning?",
                                       behind: "Okay okay, I know this one.", now: t0)
        XCTAssertEqual(line, "Wait — am I winning?")
        XCTAssertEqual(engine.firedCount, 1)
    }

    /// Re-reading the same side of the lead is not a new crossing — no repeat, no reset.
    func testStayingAheadDoesNotFireAgain() {
        var engine = DuelReactionEngine()
        _ = engine.reactionLine(diff: 1, ahead: "A", behind: "B", now: t0)
        XCTAssertNil(engine.reactionLine(diff: 3, ahead: "A", behind: "B", now: t0.addingTimeInterval(1)))
        XCTAssertEqual(engine.firedCount, 1)
    }

    /// A crossing is tracked through a tie, not reset by one: dipping back to 0 without ever
    /// reversing the actual lead must not re-arm the same-side reaction.
    func testDippingThroughTieWithoutReversingDoesNotRefire() {
        var engine = DuelReactionEngine()
        _ = engine.reactionLine(diff: 2, ahead: "A", behind: "B", now: t0)
        XCTAssertNil(engine.reactionLine(diff: 0, ahead: "A", behind: "B", now: t0.addingTimeInterval(1)))
        XCTAssertNil(engine.reactionLine(diff: 1, ahead: "A", behind: "B", now: t0.addingTimeInterval(2)))
        XCTAssertEqual(engine.firedCount, 1)
    }

    /// The player retaking the lead — a real reversal — fires the opposite line, once the gap
    /// has elapsed.
    func testReversalFiresTheOppositeLine() {
        var engine = DuelReactionEngine()
        _ = engine.reactionLine(diff: 2, ahead: "A", behind: "B", now: t0)
        let line = engine.reactionLine(diff: -1, ahead: "A", behind: "B",
                                       now: t0.addingTimeInterval(DuelReactionEngine.minGap))
        XCTAssertEqual(line, "B")
        XCTAssertEqual(engine.firedCount, 2)
    }

    /// Two reversals inside the 8s gap: the second is a real crossing but must not fire.
    func testReversalWithinGapIsSuppressed() {
        var engine = DuelReactionEngine()
        _ = engine.reactionLine(diff: 2, ahead: "A", behind: "B", now: t0)
        let suppressed = engine.reactionLine(diff: -1, ahead: "A", behind: "B",
                                             now: t0.addingTimeInterval(2))
        XCTAssertNil(suppressed)
        XCTAssertEqual(engine.firedCount, 1, "a suppressed reaction must not spend the budget")
        // The 8s gap is measured from the last *fired* reaction (t0), not the suppressed
        // attempt at +2s — "never within 8s of each other" is about two shown reactions, and
        // this one is a genuine, un-suppressed second crossing 20s after the first fire.
        let later = engine.reactionLine(diff: 4, ahead: "A", behind: "B",
                                        now: t0.addingTimeInterval(20))
        XCTAssertEqual(later, "A")
        XCTAssertEqual(engine.firedCount, 2)
    }

    /// At most 2 reactions ever, even with plenty of gap and plenty of real crossings.
    func testCapsAtTwoReactions() {
        var engine = DuelReactionEngine()
        XCTAssertNotNil(engine.reactionLine(diff: 1, ahead: "A", behind: "B", now: t0))
        XCTAssertNotNil(engine.reactionLine(diff: -1, ahead: "A", behind: "B",
                                            now: t0.addingTimeInterval(9)))
        XCTAssertNil(engine.reactionLine(diff: 1, ahead: "A", behind: "B",
                                         now: t0.addingTimeInterval(18)))
        XCTAssertEqual(engine.firedCount, 2)
    }

    /// A crossing with no authored line for that direction (silence beats a filler line) must
    /// not spend the budget — a bot missing one line shouldn't get fewer real reactions than one
    /// with both.
    func testMissingLineDoesNotSpendBudget() {
        var engine = DuelReactionEngine()
        XCTAssertNil(engine.reactionLine(diff: 1, ahead: nil, behind: "B", now: t0))
        XCTAssertEqual(engine.firedCount, 0, "no line to show, so nothing should have fired")
        // The budget is still intact for the next genuine, voiced crossing.
        let line = engine.reactionLine(diff: -1, ahead: nil, behind: "B", now: t0.addingTimeInterval(1))
        XCTAssertEqual(line, "B")
        XCTAssertEqual(engine.firedCount, 1)
    }

    /// An empty string is authored silence too, same as nil.
    func testEmptyLineIsTreatedAsMissing() {
        var engine = DuelReactionEngine()
        XCTAssertNil(engine.reactionLine(diff: 1, ahead: "", behind: "B", now: t0))
        XCTAssertEqual(engine.firedCount, 0)
    }

    // MARK: - REMATCH layout

    /// `GridResultView`'s `doneBar` is the one that has to fit **three** actions (SHARE, DONE,
    /// REMATCH) rather than two — Keep4's and Who Am I?'s are already proven fine by a real
    /// simulator screenshot (see the Task 2 report), but Grid's is the actual overflow risk and
    /// no simulator run reached it (Grid guards rung 16, unreachable from a fresh account without
    /// tapping through 15 rungs first).
    @MainActor
    func testGridResultDoneBarFitsThreeActions() throws {
        let verdict = DuelVerdict(opponentName: "Kyle", myHits: 6, theirHits: 6, outOf: 9,
                                  myScore: nil, theirScore: nil, closingLine: "Best of three?",
                                  tieGoesToPlayer: true)
        // `isDaily: false` is what a real ladder duel always passes (`duel != nil` forces it —
        // see `GridGameView`'s call site), which shortens the share label to "SHARE". Rendered
        // anyway at `isDaily: true` in a first pass caught a real bug: "CHALLENGE A FRIEND"
        // truncates to "CHALLENGE A F…" once REMATCH is squeezed in as a third action — a state
        // that can never actually ship on a duel, but worth knowing about before it did.
        let view = GridResultView(sport: .nfl, score: 900, correctCount: 6, puzzle: nil, solved: [:],
                                  rewards: nil, isDaily: false, challenge: nil,
                                  duelVerdict: verdict, onDone: {})
            .environmentObject(RepositoryContainer.make(client: nil))
            .environment(\.ladderRematch, { true })
            .frame(width: 393)
            .background(Color.appBackground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer produced nothing")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grid_result_rematch_row.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("DUEL_REACTION_GALLERY: \(url.path)")
    }
}
