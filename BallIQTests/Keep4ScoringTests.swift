import XCTest
@testable import BallIQ

final class Keep4ScoringTests: XCTestCase {

    /// Build an 8-player puzzle with grades 80...10 (descending) so the top 4 ids are p0..p3.
    private func makePuzzle() -> Keep4Puzzle {
        let players = (0..<8).map { i in
            PlayerSeason(id: "p\(i)", name: "P\(i)", teamAbbr: "TM",
                         seasonYear: 2000 + i, stats: [], grade: Double(80 - i * 10))
        }
        return Keep4Puzzle(id: "t", theme: "Test", sport: .nfl, players: players)
    }

    func testPerfectSortScoresMax() {
        let puzzle = makePuzzle()
        var placement: [String: Pile] = [:]
        for i in 0..<4 { placement["p\(i)"] = .keep }
        for i in 4..<8 { placement["p\(i)"] = .cut }

        let r = Keep4Scoring.score(puzzle: puzzle, placement: placement)
        XCTAssertEqual(r.correctCount, 8)
        XCTAssertTrue(r.isPerfect)
        XCTAssertEqual(r.total, 8 * 250 + 1000) // 3000
    }

    func testAllWrongScoresZero() {
        let puzzle = makePuzzle()
        var placement: [String: Pile] = [:]
        for i in 0..<4 { placement["p\(i)"] = .cut }   // top 4 wrongly cut
        for i in 4..<8 { placement["p\(i)"] = .keep }  // bottom 4 wrongly kept

        let r = Keep4Scoring.score(puzzle: puzzle, placement: placement)
        XCTAssertEqual(r.correctCount, 0)
        XCTAssertFalse(r.isPerfect)
        XCTAssertEqual(r.total, 0)
    }

    func testPartialScoreNoPerfectBonus() {
        let puzzle = makePuzzle()
        // Swap one keep/cut pair: 6 correct, 2 wrong.
        var placement: [String: Pile] = [:]
        for i in 0..<4 { placement["p\(i)"] = .keep }
        for i in 4..<8 { placement["p\(i)"] = .cut }
        placement["p0"] = .cut   // wrong
        placement["p4"] = .keep  // wrong

        let r = Keep4Scoring.score(puzzle: puzzle, placement: placement)
        XCTAssertEqual(r.correctCount, 6)
        XCTAssertFalse(r.isPerfect)
        XCTAssertEqual(r.total, 6 * 250) // 1500, no bonus
    }

    func testDailyIndexIsDeterministicAndInRange() {
        let comps = DateComponents(year: 2026, month: 1, day: 1)
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let a = PuzzleStore.dailyIndex(count: 5, date: date)
        let b = PuzzleStore.dailyIndex(count: 5, date: date)
        XCTAssertEqual(a, b)
        XCTAssertTrue((0..<5).contains(a))
    }

    func testBundledPuzzlesEachHaveEightPlayers() {
        for puzzle in PuzzleStore.shared.puzzles {
            XCTAssertEqual(puzzle.players.count, 8, "Puzzle \(puzzle.id) must have 8 players")
            XCTAssertEqual(puzzle.correctKeepIDs.count, 4, "Puzzle \(puzzle.id) must have 4 keep ids")
        }
    }
}
