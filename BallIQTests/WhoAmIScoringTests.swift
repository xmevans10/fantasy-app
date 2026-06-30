import XCTest
@testable import BallIQ

final class WhoAmIScoringTests: XCTestCase {

    func testFirstClueSolveScoresMax() {
        let r = WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true)
        XCTAssertEqual(r.total, 1000)
        XCTAssertEqual(r.performance, 1.0, accuracy: 0.0001)
        XCTAssertTrue(r.solved)
    }

    func testLaterClueScoresLess() {
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 3, wrongGuesses: 0, solved: true).total, 600)
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 0, solved: true).total, 100)
    }

    func testWrongGuessesDeduct() {
        let r = WhoAmIScoring.score(cluesUsed: 2, wrongGuesses: 2, solved: true)
        XCTAssertEqual(r.total, 800 - 200) // 600
    }

    func testScoreFloorsAtZero() {
        let r = WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 5, solved: true)
        XCTAssertEqual(r.total, 0) // 100 - 500, clamped
    }

    func testUnsolvedScoresZeroPerformance() {
        let r = WhoAmIScoring.score(cluesUsed: 4, wrongGuesses: 1, solved: false)
        XCTAssertEqual(r.total, 0)
        XCTAssertEqual(r.performance, 0)
        XCTAssertFalse(r.solved)
    }

    // MARK: - Answer matching

    private let answer = WhoAmIPuzzle.AcceptedAnswer(
        canonical: "Allen Iverson", aliases: ["ai", "the answer"])

    func testExactAndCaseInsensitive() {
        XCTAssertTrue(AnswerMatcher.matches("Allen Iverson", answer: answer))
        XCTAssertTrue(AnswerMatcher.matches("allen iverson", answer: answer))
    }

    func testLastNameAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("Iverson", answer: answer))
    }

    func testAliasAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("The Answer", answer: answer))
    }

    func testSingleTypoAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("Iverson", answer:
            .init(canonical: "Iverson", aliases: [])))
        XCTAssertTrue(AnswerMatcher.matches("Iversen", answer:
            .init(canonical: "Iverson", aliases: [])))
    }

    func testWrongAnswerRejected() {
        XCTAssertFalse(AnswerMatcher.matches("Kobe Bryant", answer: answer))
        XCTAssertFalse(AnswerMatcher.matches("", answer: answer))
    }
}
