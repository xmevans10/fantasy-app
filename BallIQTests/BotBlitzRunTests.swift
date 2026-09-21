import XCTest
@testable import BallIQ

/// The ladder's comparable is a blitz run now, so these pin the properties the curve depends on:
/// the clock gates boards rather than truncating them, skill buys both accuracy and board count,
/// and the points a bot reports are the same arithmetic a player's run is scored by.
final class BotBlitzRunTests: XCTestCase {

    // MARK: - The clock

    func testTheClockGatesTheNextBoardAndNeverCutsOneShort() {
        // Keep4 par is 120s, so a 300s run fits two or three depending on pace — and whichever
        // it is, every board that WAS played got its full share of the clock.
        let run = BotSolver.playBlitz(boards: Self.boards(count: 8), skill: 0.8, seed: 1,
                                      duration: 300)
        XCTAssertLessThanOrEqual(run.elapsed, 300)
        XCTAssertEqual(run.elapsed, run.rounds.map(\.elapsed).reduce(0, +), accuracy: 1e-9)
        XCTAssertFalse(run.rounds.isEmpty)
        for round in run.rounds {
            XCTAssertGreaterThan(round.elapsed, 0, "a played board has to have cost real time")
        }
    }

    /// The measured finding that set the duration ladder: at 60 seconds a weak side cannot
    /// finish a single long board, because keep4's par alone is 120s and a weak side spends
    /// ~0.97 of par. A one-minute rung is therefore only honest where the target sits above the
    /// format's own floor — see `LadderBlitz.duration(forRung:)`.
    func testAWeakBotFinishesNothingInAMinuteOfLongBoards() {
        let run = BotSolver.playBlitz(boards: Self.boards(count: 8), skill: 0.05, seed: 3,
                                      duration: 60)
        XCTAssertEqual(run.boardsPlayed, 0)
        XCTAssertEqual(run.points, 0)
    }

    func testAStrongBotGetsThroughMoreBoardsThanAWeakOne() {
        let weak = BotSolver.playBlitz(boards: Self.boards(count: 12), skill: 0.2, seed: 5,
                                       duration: 300)
        let strong = BotSolver.playBlitz(boards: Self.boards(count: 12), skill: 0.95, seed: 5,
                                         duration: 300)
        XCTAssertGreaterThan(strong.boardsPlayed, weak.boardsPlayed,
                             "pace is half the divergence surface — skill has to buy board count")
    }

    // MARK: - Scoring

    /// The bot reports the number a player's run is scored by, not a parallel one.
    func testPointsAreBlitzScoringOverTheSameRounds() {
        let run = BotSolver.playBlitz(boards: Self.boards(count: 6), skill: 0.7, seed: 9,
                                      duration: 300)
        XCTAssertEqual(run.points, BlitzScoring.total(run.rounds))
    }

    /// `cleared` drives the combo, so it has to mean what `BlitzScoring` means by it: past the
    /// format's chance floor, not merely non-zero.
    func testClearedIsMeasuredAgainstTheFormatsChanceFloor() {
        let run = BotSolver.playBlitz(boards: Self.boards(count: 8), skill: 0.6, seed: 11,
                                      duration: 300)
        for round in run.rounds {
            XCTAssertEqual(round.cleared, round.performance > round.format.chanceFloor)
        }
    }

    /// The whole reason the ladder moved here: keep4's forced 4/4 split pays chance, so a
    /// deliberately bad sorter still scores about half the board and no `bot_skill` could take
    /// the player's win rate below ~0.27. `surplus` rebases chance to exactly zero, so on a
    /// board that is genuinely all coin flips a minimum-skill bot is paid nothing.
    func testChanceIsWorthNothingOnABoardOfCoinFlips() {
        let run = BotSolver.playBlitz(boards: Self.hardKeep4Only(count: 10), skill: 0.05,
                                      seed: 13, duration: 900)
        XCTAssertGreaterThan(run.boardsPlayed, 0, "900s is long enough to play several boards")
        XCTAssertEqual(run.points, 0)
    }

    /// The other half of the same truth, and the one that shaped the duration ladder: an EASY
    /// board pays a weak bot anyway, because a card far from the keep/cut line is a gimme at any
    /// skill (`hitProbability` is 1 at difficulty 0). Blitz does not repeal that — it survives it
    /// by aggregating several boards, where the old single-board rungs could not.
    ///
    /// Pinned rather than merely noted: if this ever returned 0 it would mean the per-card
    /// difficulty model had stopped treating obvious calls as obvious.
    func testAnEasyBoardStillPaysAWeakBotWhichIsWhyOneBoardCouldNeverBeARung() {
        let run = BotSolver.playBlitz(boards: Self.keep4Only(count: 10), skill: 0.05, seed: 13,
                                      duration: 900)
        XCTAssertGreaterThan(run.points, 0)
    }

    func testMoreSkillScoresMoreAcrossSeeds() {
        func meanPoints(_ skill: Double) -> Double {
            let runs = (UInt64(1)...60).map {
                BotSolver.playBlitz(boards: Self.boards(count: 12), skill: skill, seed: $0,
                                    duration: 300)
            }
            return Double(runs.reduce(0) { $0 + $1.points }) / Double(runs.count)
        }
        XCTAssertLessThan(meanPoints(0.3), meanPoints(0.6))
        XCTAssertLessThan(meanPoints(0.6), meanPoints(0.95))
    }

    // MARK: - Reproducibility

    func testARunIsReproducibleForASeed() {
        let a = BotSolver.playBlitz(boards: Self.boards(count: 10), skill: 0.65, seed: 77,
                                    duration: 300)
        let b = BotSolver.playBlitz(boards: Self.boards(count: 10), skill: 0.65, seed: 77,
                                    duration: 300)
        XCTAssertEqual(a.points, b.points)
        XCTAssertEqual(a.boardsPlayed, b.boardsPlayed)
        XCTAssertEqual(a.elapsed, b.elapsed, accuracy: 1e-12)
    }

    // MARK: - Over/Under difficulty

    /// A call right on the line is the hardest there is; one far from it is a gimme. Same shape
    /// as `keep4Difficulty`, and the sign is the part worth pinning.
    func testOverUnderDifficultyFallsAsTheGapFromTheLineGrows() {
        let onTheLine = Self.overUnder(actual: 1000, threshold: 1000)
        let close = Self.overUnder(actual: 1000, threshold: 980)
        let obvious = Self.overUnder(actual: 1000, threshold: 400)
        XCTAssertEqual(BotSolver.overUnderDifficulty(onTheLine), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(BotSolver.overUnderDifficulty(close),
                             BotSolver.overUnderDifficulty(obvious))
        XCTAssertEqual(BotSolver.overUnderDifficulty(obvious), 0, accuracy: 1e-9)
    }

    /// A threshold at zero is reachable on rate stats; dividing by it would report every such
    /// call as a certainty rather than a coin flip.
    func testAZeroLineDegradesToACoinFlipRatherThanDividingByNothing() {
        XCTAssertEqual(BotSolver.overUnderDifficulty(Self.overUnder(actual: 0, threshold: 0)), 1)
    }

    // MARK: - Duration ladder

    func testDurationRisesWithTheRungAndBossesGetTheLongest() {
        XCTAssertEqual(LadderBlitz.duration(forRung: 1, isBoss: false), .one)
        XCTAssertEqual(LadderBlitz.duration(forRung: LadderBlitz.oneMinuteMaxRung, isBoss: false), .one)
        XCTAssertEqual(LadderBlitz.duration(forRung: LadderBlitz.oneMinuteMaxRung + 1, isBoss: false), .three)
        XCTAssertEqual(LadderBlitz.duration(forRung: 29, isBoss: false), .three)
        for boss in [10, 20, 30] {
            XCTAssertEqual(LadderBlitz.duration(forRung: boss, isBoss: true), .five)
        }
    }

    // MARK: - Fixtures

    /// A mixed sequence, the shape a real run draws.
    private static func boards(count: Int) -> [BlitzBoard] {
        (0..<count).map { i in
            switch i % 4 {
            case 0: return .keep4(keep4(id: "k\(i)"))
            case 1: return .whoami(whoami(id: "w\(i)"))
            case 2: return .journeyman(journeyman(id: "j\(i)"))
            default: return .overunder(overUnder(actual: 1000, threshold: 940, id: "o\(i)"), .nfl)
            }
        }
    }

    private static func keep4Only(count: Int) -> [BlitzBoard] {
        (0..<count).map { .keep4(keep4(id: "k\($0)")) }
    }

    /// Grades clustered hard against the keep/cut line, so every card is a genuine coin flip
    /// (relative gap ~0.5%, well inside `keep4ObviousRelativeGap`) and nothing is a gimme.
    private static func hardKeep4Only(count: Int) -> [BlitzBoard] {
        (0..<count).map { i in
            let grades: [Double] = [101, 101, 101, 101, 100, 100, 100, 100]
            let players = grades.enumerated().map { j, g in
                PlayerSeason(id: "h\(i)-p\(j)", name: "P\(j)", teamAbbr: "TM",
                             seasonYear: 2000 + j, stats: [], grade: g)
            }
            return .keep4(Keep4Puzzle(id: "h\(i)", theme: "Coin flips", sport: .nfl,
                                      players: players))
        }
    }

    private static func keep4(id: String) -> Keep4Puzzle {
        let grades: [Double] = [118, 112, 106, 103, 100, 97, 91, 85]
        let players = grades.enumerated().map { i, g in
            PlayerSeason(id: "\(id)-p\(i)", name: "P\(i)", teamAbbr: "TM",
                         seasonYear: 2000 + i, stats: [], grade: g)
        }
        return Keep4Puzzle(id: id, theme: "Fixture", sport: .nfl, players: players)
    }

    private static func whoami(id: String) -> WhoAmIPuzzle {
        let clues = (1...6).map { WhoAmIPuzzle.Clue(order: $0, kind: .fact, text: "Clue \($0)") }
        return WhoAmIPuzzle(id: id, sport: .nba, clues: clues,
                            answer: .init(canonical: "Test Player", aliases: []),
                            difficulty: .medium)
    }

    private static func journeyman(id: String) -> JourneymanPuzzle {
        JourneymanPuzzle(
            id: id, sport: .soccer,
            stints: (1...4).map {
                JourneymanPuzzle.Stint(order: $0, teamAbbr: "NO", teamName: "Club \($0)",
                                       league: "", firstYear: 2000 + $0, lastYear: 2000 + $0)
            },
            answer: .init(canonical: "Test Player", aliases: []),
            difficulty: .medium, position: "QB", headshot: nil)
    }

    private static func overUnder(actual: Double, threshold: Double,
                                  id: String = "ou") -> OverUnderRound {
        let season = CatalogSeason(id: "\(id)-s", sport: .nfl, name: "Player", teamAbbr: "SF",
                                   seasonYear: 2015, position: "RB",
                                   stats: ["rushing_yards": actual])
        return OverUnderRound(id: id, player: season,
                              stat: ScoringStat.find("rushing_yards", sport: .nfl)!,
                              threshold: threshold)
    }
}
