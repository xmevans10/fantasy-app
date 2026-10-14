import XCTest
@testable import BallIQ

@MainActor
final class MyTeamsTests: XCTestCase {
    func testCompletionAndOfflineOutboxSurviveRestartAndCannotDuplicate() throws {
        let defaults = UserDefaults(suiteName: "MyTeamsTests.\(UUID().uuidString)")!
        let repo = TeamPuzzleRepository(client: nil, defaults: defaults)
        repo.stage(id: "team-test", keepIDs: ["d","b","a","c"], guest: false)
        repo.stage(id: "team-test", keepIDs: ["x"], guest: false)
        let restored = TeamPuzzleRepository(client: nil, defaults: defaults)
        XCTAssertEqual(restored.state.completed, ["team-test"])
        XCTAssertEqual(restored.state.pending.count, 1)
        XCTAssertEqual(restored.state.pending[0].keepIDs, ["a","b","c","d"])
        restored.acknowledge("team-test")
        let again = TeamPuzzleRepository(client: nil, defaults: defaults)
        XCTAssertTrue(again.state.pending.isEmpty)
        XCTAssertTrue(again.state.completed.contains("team-test"))
        again.reset()
        XCTAssertTrue(TeamPuzzleRepository(client: nil, defaults: defaults).state.completed.isEmpty)
    }
    func testBundledStarterAndExactKeep4Contract() throws {
        let boards = TeamPuzzleRepository.bundled()
        XCTAssertGreaterThanOrEqual(boards.count, 12)
        XCTAssertEqual(boards.filter(\.isStarter).count, 1)
        for board in boards {
            XCTAssertEqual(board.id, board.content.id)
            XCTAssertEqual(board.content.players.count, 8)
            XCTAssertEqual(Set(board.content.players.map(\.id)).count, 8)
            XCTAssertTrue(board.content.players.allSatisfy { $0.teamAbbr == "NO" })
            let grades = board.content.players.map(\.grade).sorted(by: >)
            XCTAssertGreaterThan(grades[3], grades[4])
            let placement = Dictionary(uniqueKeysWithValues: board.content.players.map { ($0.id, board.content.correctKeepIDs.contains($0.id) ? Pile.keep : .cut) })
            XCTAssertTrue(Keep4Scoring.score(puzzle: board.content, placement: placement).isPerfect)
        }
    }
    func testCareerCurvePreservesExistingLevelsAndTransitions() {
        for xp in stride(from: 0, through: 200_000, by: 31) {
            XCTAssertGreaterThanOrEqual(LevelCurve.level(forXP: xp), Int((Double(xp)/100).squareRoot())+1)
        }
        for level in 2...100 {
            let threshold = LevelCurve.xpToReach(level: level)
            XCTAssertEqual(LevelCurve.level(forXP: threshold-1), level-1)
            XCTAssertEqual(LevelCurve.level(forXP: threshold), level)
        }
    }
}
