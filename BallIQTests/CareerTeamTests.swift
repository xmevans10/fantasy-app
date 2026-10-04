import XCTest
@testable import BallIQ

final class CareerTeamTests: XCTestCase {
    func testEarlyLevelsAndExistingProgressArePreserved() {
        for level in 1...10 {
            XCTAssertEqual(LevelCurve.xpToReach(level: level), (level - 1) * (level - 1) * 100)
        }
        for xp in stride(from: 0, through: 100_000, by: 37) {
            let oldLevel = Int((Double(xp) / 100).squareRoot()) + 1
            XCTAssertGreaterThanOrEqual(LevelCurve.level(forXP: xp), oldLevel)
        }
    }
    func testThresholdTransitionsAndSteadyPacing() {
        for level in 2...100 {
            let threshold = LevelCurve.xpToReach(level: level)
            XCTAssertEqual(LevelCurve.level(forXP: threshold - 1), level - 1)
            XCTAssertEqual(LevelCurve.level(forXP: threshold), level)
            let p = LevelCurve.progress(forXP: threshold)
            XCTAssertEqual(p.intoLevel, 0)
            if level >= 10 { XCTAssertEqual(p.span, 1900) }
        }
        XCTAssertEqual(LevelCurve.progress(forXP: -10).intoLevel, 0)
        XCTAssertEqual(LevelCurve.title(for: 20), "Veteran")
        XCTAssertEqual(LevelCurve.nextMilestone(after: 20)?.level, 35)
        XCTAssertNil(LevelCurve.nextMilestone(after: 50))
    }
    private func puzzle(teams: [String], sport: Sport = .nfl) -> Keep4Puzzle {
        Keep4Puzzle(id: "test", theme: "Team seasons", sport: sport,
                    players: teams.enumerated().map { index, team in
            PlayerSeason(id: "p\(index)", name: "Player \(index)", teamAbbr: team,
                         seasonYear: 2020, stats: [], grade: Double(index))
        })
    }
    func testExclusiveTeamDoesNotMeanOneFavoritePlayer() {
        let eight = Array(repeating: "NYJ", count: 8)
        XCTAssertTrue(puzzle(teams: eight).isExclusive(to: "nyj", sport: .nfl))
        XCTAssertFalse(puzzle(teams: ["NYG"] + Array(eight.dropFirst())).isExclusive(to: "NYJ", sport: .nfl))
        XCTAssertFalse(puzzle(teams: eight).isExclusive(to: "NYJ", sport: .nba))
        XCTAssertFalse(puzzle(teams: Array(eight.prefix(7))).isExclusive(to: "NYJ", sport: .nfl))
        XCTAssertFalse(puzzle(teams: Array(repeating: "", count: 8)).isExclusive(to: "", sport: .nfl))
        var duplicate = puzzle(teams: eight)
        duplicate = Keep4Puzzle(id: duplicate.id, theme: duplicate.theme, sport: .nfl,
                                players: Array(repeating: duplicate.players[0], count: 8))
        XCTAssertFalse(duplicate.isExclusive(to: "NYJ", sport: .nfl))
    }
}
