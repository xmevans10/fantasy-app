import XCTest
@testable import BallIQ

final class GridRunStateTests: XCTestCase {
    private var puzzle: GridPuzzle {
        GridPuzzle(sport: .nfl,
                   rows: ["KC", "SF", "NE"].map { .init(kind: .team, label: $0) },
                   cols: ["1980s", "1990s", "2000s"].map { .init(kind: .decade, label: $0) },
                   cells: (0..<9).map { _ in .init(validAnswerIds: ["joe"], validAnswerNames: ["Joe Montana"], rarityStars: 2) })
    }
    func testMissCanBeRetriedAndConsumesSharedBudget() {
        var run = GridRunState()
        XCTAssertEqual(run.submit("Nobody", at: 0, puzzle: puzzle), false)
        XCTAssertEqual(run.remaining, 8)
        XCTAssertEqual(run.submit("Joe Montana", at: 0, puzzle: puzzle), true)
        XCTAssertEqual(run.remaining, 7)
        XCTAssertEqual(run.solved[0], "Joe Montana")
        XCTAssertTrue(run.unsolvedMisses.isEmpty)
        XCTAssertEqual(run.attempts.map(\.correct), [false, true])
        XCTAssertEqual(run.finalCellAttempts, [.init(cell: 0, name: "Joe Montana", correct: true)])
    }
    func testDuplicatesSolvedCellsAndEmptyInputSpendNoGuess() {
        var run = GridRunState()
        _ = run.submit("Joe Montana", at: 0, puzzle: puzzle)
        XCTAssertNil(run.submit("Montana", at: 1, puzzle: puzzle))
        XCTAssertNil(run.submit("Joe Montanna", at: 1, puzzle: puzzle))
        XCTAssertNil(run.submit("Someone Else", at: 0, puzzle: puzzle))
        XCTAssertNil(run.submit("  ", at: 2, puzzle: puzzle))
        XCTAssertNil(run.submit("Someone Else", at: 9, puzzle: puzzle))
        XCTAssertEqual(run.remaining, 8)
    }
    func testNineMissesOnOneCellExhaustBudgetAndRetainLastCrowdPick() {
        var run = GridRunState()
        for i in 0..<9 { XCTAssertEqual(run.submit("Nobody \(i)", at: 0, puzzle: puzzle), false) }
        XCTAssertEqual(run.remaining, 0)
        XCTAssertNil(run.submit("Joe Montana", at: 1, puzzle: puzzle))
        XCTAssertEqual(run.finalCellAttempts, [.init(cell: 0, name: "Nobody 8", correct: false)])
    }
    func testEarlyFinishLogsActualAttemptsWithoutChangingHistoricalScore() {
        let detail = GridGameView.buildSessionDetail(puzzle: puzzle, solved: [0: "Joe Montana"],
                                                    wrong: [1], mode: .practice, startedAt: nil, attempted: 3)
        XCTAssertEqual(detail.attempted, 3)
        XCTAssertEqual(detail.correct, 1)
        XCTAssertEqual(detail.score, 140)
    }
    func testScreenshotAssignmentMovesEarlierChoiceInsteadOfReusingPlayer() {
        let cells = (0..<9).map { i in
            GridPuzzle.GridCell(validAnswerIds: [],
                                validAnswerNames: i == 0 ? ["Player 1", "Player 0"] : ["Player \(i)"],
                                rarityStars: 1)
        }
        let board = GridPuzzle(sport: .nfl, rows: puzzle.rows, cols: puzzle.cols, cells: cells)
        let assignment = GridRunState.distinctAnswerAssignment(board)
        XCTAssertEqual(assignment.count, 9)
        XCTAssertEqual(Set(assignment.values).count, 9)
        XCTAssertEqual(assignment[0], "Player 0")
        XCTAssertEqual(assignment[1], "Player 1")
    }

}
