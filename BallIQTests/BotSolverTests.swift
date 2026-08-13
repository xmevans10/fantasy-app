import XCTest
@testable import BallIQ

final class BotSolverTests: XCTestCase {

    // MARK: - Fixtures

    /// 8 cards descending, correct split p0...p3 keep / p4...p7 cut — same shape as
    /// `Keep4ScoringTests.makePuzzle`, so it stays easy to reason about by hand.
    ///
    /// **The grade spacing is deliberately realistic and load-bearing.** `BotSolver` derives a
    /// card's difficulty from its distance to the keep/cut cutoff as a fraction of the board's
    /// grade magnitude (see `keep4Difficulty(of:in:)`), so a fixture's *spacing* decides whether
    /// it is a hard board or a trivial one. The old fixture ran 80/70/.../10 — 22% steps on a
    /// 45-point scale, which the metric correctly calls a board of pure gimmes, and every
    /// skill-sensitivity test silently became "1.0 vs 1.0". Real boards are far tighter: measured
    /// over the live pool, the gap right at the cutoff averages 1.5%-4.8% of magnitude. These
    /// grades reproduce that.
    private func keep4Puzzle(spread: Double = 1.0) -> Keep4Puzzle {
        let offsets = [20.0, 12, 6, 2, -2, -6, -12, -20]   // ~0.7%-6.7% of magnitude at spread 1
        let players = offsets.enumerated().map { i, offset in
            PlayerSeason(id: "p\(i)", name: "P\(i)", teamAbbr: "TM",
                        seasonYear: 2000 + i, stats: [], grade: 300 + offset * spread)
        }
        return Keep4Puzzle(id: "t", theme: "Test", sport: .nfl, players: players)
    }

    /// The same board pulled far apart, so every call is obvious. Used to pin that the metric
    /// actually responds to the scoring metric rather than to card ordering.
    private func keep4ObviousPuzzle() -> Keep4Puzzle { keep4Puzzle(spread: 12) }

    /// A 3x3 board whose rarity spans the full 1...5 range at least twice, so both the easiest
    /// and hardest cells are represented — mirrors `GridPuzzleTests.puzzle`.
    private func gridPuzzle() -> GridPuzzle {
        let rows = ["CLE", "SEA", "LA"].map { GridPuzzle.GridAxis(kind: .team, label: $0) }
        let cols = ["1990s", "2010s", "2020s"].map { GridPuzzle.GridAxis(kind: .decade, label: $0) }
        let cells = (0..<9).map { i in
            GridPuzzle.GridCell(validAnswerIds: ["id-\(i)"], validAnswerNames: ["Player \(i)"],
                                rarityStars: (i % 5) + 1)
        }
        return GridPuzzle(sport: .nfl, rows: rows, cols: cols, cells: cells)
    }

    /// 6 clues, the format's standard count — matches the shape `WhoAmIScoring.perClue` assumes.
    private func whoAmIPuzzle(difficulty: WhoAmIPuzzle.Difficulty? = nil) -> WhoAmIPuzzle {
        let clues = (1...6).map { WhoAmIPuzzle.Clue(order: $0, kind: .fact, text: "Clue \($0)") }
        return WhoAmIPuzzle(id: "w", sport: .nba, clues: clues,
                            answer: .init(canonical: "Test Player", aliases: []), difficulty: difficulty)
    }

    // MARK: - hitProbability

    func testHitProbabilityStaysInUnitRange() {
        for skillTenth in 0...10 {
            for difficultyTenth in 0...10 {
                let p = BotSolver.hitProbability(skill: Double(skillTenth) / 10,
                                                 difficulty: Double(difficultyTenth) / 10)
                XCTAssertGreaterThanOrEqual(p, 0)
                XCTAssertLessThanOrEqual(p, 1)
            }
        }
    }

    func testHitProbabilityIncreasesWithSkill() {
        for difficultyTenth in stride(from: 1, through: 10, by: 1) {
            let difficulty = Double(difficultyTenth) / 10
            var previous = BotSolver.hitProbability(skill: 0, difficulty: difficulty)
            for skillTenth in stride(from: 1, through: 10, by: 1) {
                let p = BotSolver.hitProbability(skill: Double(skillTenth) / 10, difficulty: difficulty)
                XCTAssertGreaterThanOrEqual(p, previous, "difficulty \(difficulty)")
                previous = p
            }
        }
    }

    func testHitProbabilityDecreasesWithDifficulty() {
        for skillTenth in stride(from: 1, through: 9, by: 1) {
            let skill = Double(skillTenth) / 10
            var previous = BotSolver.hitProbability(skill: skill, difficulty: 0)
            for difficultyTenth in stride(from: 1, through: 10, by: 1) {
                let p = BotSolver.hitProbability(skill: skill, difficulty: Double(difficultyTenth) / 10)
                XCTAssertLessThanOrEqual(p, previous, "skill \(skill)")
                previous = p
            }
        }
    }

    /// The spec's own worked example: a weak bot must still nail the gimmes and fumble the
    /// hardest calls, or the whole "skill-limited human-like" premise falls apart.
    func testWeakBotNailsGimmesAndFumblesTheHardestCalls() {
        let gimme = BotSolver.hitProbability(skill: 0.35, difficulty: 0)
        let hardest = BotSolver.hitProbability(skill: 0.35, difficulty: 1)
        XCTAssertGreaterThan(gimme, 0.95)
        XCTAssertLessThan(hardest, 0.5)
    }

    // MARK: - Determinism

    func testKeep4IsFullySeeded() {
        let puzzle = keep4Puzzle()
        let a = BotSolver.playKeep4(puzzle, skill: 0.6, seed: 42, timeLimit: 90)
        let b = BotSolver.playKeep4(puzzle, skill: 0.6, seed: 42, timeLimit: 90)
        XCTAssertEqual(a, b)
    }

    func testGridIsFullySeeded() {
        let puzzle = gridPuzzle()
        let a = BotSolver.playGrid(puzzle, skill: 0.6, seed: 42, timeLimit: 90)
        let b = BotSolver.playGrid(puzzle, skill: 0.6, seed: 42, timeLimit: 90)
        XCTAssertEqual(a, b)
    }

    func testWhoAmIIsFullySeeded() {
        let puzzle = whoAmIPuzzle()
        let a = BotSolver.playWhoAmI(puzzle, skill: 0.6, seed: 42, timeLimit: 90)
        let b = BotSolver.playWhoAmI(puzzle, skill: 0.6, seed: 42, timeLimit: 90)
        XCTAssertEqual(a, b)
    }

    /// A different seed on the same inputs must be able to diverge — otherwise "fully seeded"
    /// would be true only because the RNG is never actually consulted.
    func testDifferentSeedsCanProduceDifferentRuns() {
        let puzzle = keep4Puzzle()
        let runs = (0..<20).map { BotSolver.playKeep4(puzzle, skill: 0.5, seed: UInt64($0), timeLimit: 90) }
        XCTAssertGreaterThan(Set(runs.map(\.correct)).count, 1,
                             "20 different seeds at skill 0.5 all produced the same correct count")
    }

    // MARK: - Beat shape

    private func assertBeatsWellFormed(_ run: BotRun, timeLimit: TimeInterval, expectedCount: Int,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.beats.count, expectedCount, file: file, line: line)
        var previous: TimeInterval = 0
        for beat in run.beats {
            XCTAssertGreaterThan(beat.at, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(beat.at, timeLimit, file: file, line: line)
            XCTAssertGreaterThanOrEqual(beat.at, previous, file: file, line: line)
            previous = beat.at
        }
        XCTAssertEqual(run.elapsed, run.beats.last?.at ?? 0, file: file, line: line)
    }

    func testKeep4BeatsAreMonotonicAndBounded() {
        let puzzle = keep4Puzzle()
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            let run = BotSolver.playKeep4(puzzle, skill: 0.5, seed: seed, timeLimit: 60)
            assertBeatsWellFormed(run, timeLimit: 60, expectedCount: 8)
        }
    }

    func testGridBeatsAreMonotonicAndBounded() {
        let puzzle = gridPuzzle()
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            let run = BotSolver.playGrid(puzzle, skill: 0.5, seed: seed, timeLimit: 60)
            assertBeatsWellFormed(run, timeLimit: 60, expectedCount: 9)
        }
    }

    func testWhoAmIBeatsAreMonotonicAndBoundedAndOnePerClueRevealed() {
        let puzzle = whoAmIPuzzle()
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            let run = BotSolver.playWhoAmI(puzzle, skill: 0.5, seed: seed, timeLimit: 60)
            // Clue count revealed varies by seed/skill — bound is "at most all 6 clues", not
            // a fixed count like Keep4/Grid's every-decision formats.
            XCTAssertGreaterThanOrEqual(run.beats.count, 1)
            XCTAssertLessThanOrEqual(run.beats.count, 6)
            assertBeatsWellFormed(run, timeLimit: 60, expectedCount: run.beats.count)
        }
    }

    // MARK: - performance always in 0...1

    func testPerformanceIsAlwaysInUnitRangeAcrossManySeedsAndSkills() {
        let keep4 = keep4Puzzle()
        let grid = gridPuzzle()
        let whoAmI = whoAmIPuzzle()
        for seed: UInt64 in 0..<40 {
            for skill in [0.0, 0.35, 0.6, 0.9, 1.0] {
                for run in [BotSolver.playKeep4(keep4, skill: skill, seed: seed, timeLimit: 90),
                           BotSolver.playGrid(grid, skill: skill, seed: seed, timeLimit: 90)] {
                    XCTAssertGreaterThanOrEqual(run.performance, 0)
                    XCTAssertLessThanOrEqual(run.performance, 1)
                }
                let whoAmIRun = BotSolver.playWhoAmI(whoAmI, skill: skill, seed: seed, timeLimit: 90)
                XCTAssertGreaterThanOrEqual(whoAmIRun.performance, 0)
                XCTAssertLessThanOrEqual(whoAmIRun.performance, 1)
            }
        }
    }

    // MARK: - Keep4's pile cap

    /// A bot that keeps 6 isn't playing the same game — the cap has to hold at every skill and
    /// every seed, not just on average.
    func testKeep4AlwaysRespectsTheFourFourCap() {
        let puzzle = keep4Puzzle()
        for seed: UInt64 in 0..<40 {
            for skill in [0.0, 0.2, 0.35, 0.5, 0.7, 0.9, 1.0] {
                let counts = BotSolver.keep4PileCounts(puzzle, skill: skill, seed: seed)
                XCTAssertEqual(counts.keep, 4, "skill \(skill) seed \(seed)")
                XCTAssertEqual(counts.cut, 4, "skill \(skill) seed \(seed)")
            }
        }
    }

    /// At skill 1.0 every card's own `correctVerdict` already IS a valid 4/4 split, so no
    /// flip-correction is ever needed and the run is exactly perfect.
    func testKeep4MaxSkillIsExactlyPerfect() {
        let puzzle = keep4Puzzle()
        for seed: UInt64 in 0..<20 {
            let run = BotSolver.playKeep4(puzzle, skill: 1.0, seed: seed, timeLimit: 90)
            XCTAssertEqual(run.correct, 8)
        }
    }

    // MARK: - Skill separation (aggregate)

    private func meanPerformance(_ runs: [BotRun]) -> Double {
        runs.map(\.performance).reduce(0, +) / Double(runs.count)
    }

    private func meanElapsed(_ runs: [BotRun]) -> Double {
        runs.map(\.elapsed).reduce(0, +) / Double(runs.count)
    }

    func testHigherSkillScoresBetterInAggregateAcrossAllThreeFormats() {
        let seeds: [UInt64] = Array(0..<60)
        let keep4 = keep4Puzzle(), grid = gridPuzzle(), whoAmI = whoAmIPuzzle()

        let weakKeep4 = seeds.map { BotSolver.playKeep4(keep4, skill: 0.35, seed: $0, timeLimit: 90) }
        let strongKeep4 = seeds.map { BotSolver.playKeep4(keep4, skill: 0.9, seed: $0, timeLimit: 90) }
        XCTAssertGreaterThan(meanPerformance(strongKeep4), meanPerformance(weakKeep4) + 0.1)

        let weakGrid = seeds.map { BotSolver.playGrid(grid, skill: 0.35, seed: $0, timeLimit: 90) }
        let strongGrid = seeds.map { BotSolver.playGrid(grid, skill: 0.9, seed: $0, timeLimit: 90) }
        XCTAssertGreaterThan(meanPerformance(strongGrid), meanPerformance(weakGrid) + 0.1)

        let weakWhoAmI = seeds.map { BotSolver.playWhoAmI(whoAmI, skill: 0.35, seed: $0, timeLimit: 90) }
        let strongWhoAmI = seeds.map { BotSolver.playWhoAmI(whoAmI, skill: 0.9, seed: $0, timeLimit: 90) }
        XCTAssertGreaterThan(meanPerformance(strongWhoAmI), meanPerformance(weakWhoAmI) + 0.1)
    }

    func testHigherSkillIsFasterAcrossAllThreeFormats() {
        let seeds: [UInt64] = Array(0..<60)
        let keep4 = keep4Puzzle(), grid = gridPuzzle(), whoAmI = whoAmIPuzzle()

        let weakKeep4 = seeds.map { BotSolver.playKeep4(keep4, skill: 0.35, seed: $0, timeLimit: 90) }
        let strongKeep4 = seeds.map { BotSolver.playKeep4(keep4, skill: 0.95, seed: $0, timeLimit: 90) }
        XCTAssertLessThan(meanElapsed(strongKeep4), meanElapsed(weakKeep4))

        let weakGrid = seeds.map { BotSolver.playGrid(grid, skill: 0.35, seed: $0, timeLimit: 90) }
        let strongGrid = seeds.map { BotSolver.playGrid(grid, skill: 0.95, seed: $0, timeLimit: 90) }
        XCTAssertLessThan(meanElapsed(strongGrid), meanElapsed(weakGrid))

        let weakWhoAmI = seeds.map { BotSolver.playWhoAmI(whoAmI, skill: 0.35, seed: $0, timeLimit: 90) }
        let strongWhoAmI = seeds.map { BotSolver.playWhoAmI(whoAmI, skill: 0.95, seed: $0, timeLimit: 90) }
        XCTAssertLessThan(meanElapsed(strongWhoAmI), meanElapsed(weakWhoAmI))
    }

    // MARK: - Extremes

    func testMaxSkillIsNearPerfectAcrossAllThreeFormats() {
        let seeds: [UInt64] = Array(0..<30)
        let keep4 = keep4Puzzle(), grid = gridPuzzle(), whoAmI = whoAmIPuzzle()
        XCTAssertGreaterThan(meanPerformance(seeds.map { BotSolver.playKeep4(keep4, skill: 1.0, seed: $0, timeLimit: 90) }), 0.95)
        XCTAssertGreaterThan(meanPerformance(seeds.map { BotSolver.playGrid(grid, skill: 1.0, seed: $0, timeLimit: 90) }), 0.95)
        XCTAssertGreaterThan(meanPerformance(seeds.map { BotSolver.playWhoAmI(whoAmI, skill: 1.0, seed: $0, timeLimit: 90) }), 0.9)
    }

    func testZeroSkillIsNearFloorAcrossAllThreeFormats() {
        let seeds: [UInt64] = Array(0..<30)
        let keep4 = keep4Puzzle(), grid = gridPuzzle(), whoAmI = whoAmIPuzzle()
        XCTAssertLessThan(meanPerformance(seeds.map { BotSolver.playKeep4(keep4, skill: 0.0, seed: $0, timeLimit: 90) }), 0.5)
        XCTAssertLessThan(meanPerformance(seeds.map { BotSolver.playGrid(grid, skill: 0.0, seed: $0, timeLimit: 90) }), 0.5)
        XCTAssertLessThan(meanPerformance(seeds.map { BotSolver.playWhoAmI(whoAmI, skill: 0.0, seed: $0, timeLimit: 90) }), 0.4)
    }

    // MARK: - Who Am I? routes through WhoAmIScoring, not a duplicated formula

    /// Every solved run's `performance` must be one of `WhoAmIScoring`'s own per-clue ratios —
    /// proof the solver calls through `WhoAmIScoring.score` rather than reimplementing it.
    func testWhoAmIPerformanceMatchesWhoAmIScoringExactly() {
        let puzzle = whoAmIPuzzle()
        let validRatios = Set(WhoAmIScoring.perClue.map { Double($0) / Double(WhoAmIScoring.perClue[0]) } + [0])
        for seed: UInt64 in 0..<50 {
            let run = BotSolver.playWhoAmI(puzzle, skill: 0.5, seed: seed, timeLimit: 90)
            XCTAssertTrue(validRatios.contains(run.performance), "\(run.performance) not a valid WhoAmIScoring ratio")
        }
    }

    // MARK: - Difficulty comes from the scoring metric

    /// A board whose grades are tightly bunched around the keep/cut line is hard; the same
    /// board pulled apart is easy. This is the property the whole ladder calibration rests on,
    /// and it is a statement about `grade` — the puzzle's own scoring metric — not about
    /// anything the solver invents.
    func testGradeSpacingDecidesDifficulty() {
        let tight = keep4Puzzle()
        let obvious = keep4ObviousPuzzle()
        let tightD = tight.players.map { BotSolver.keep4Difficulty(of: $0, in: tight) }
        let obviousD = obvious.players.map { BotSolver.keep4Difficulty(of: $0, in: obvious) }

        XCTAssertGreaterThan(tightD.reduce(0, +) / 8, 0.4, "a bunched board should be hard")
        XCTAssertLessThan(obviousD.reduce(0, +) / 8, 0.1, "a spread-out board should be a gimme")
        // Within a board, the cards nearest the cutoff are the hardest calls.
        XCTAssertGreaterThan(tightD[3], tightD[0])
        XCTAssertGreaterThan(tightD[4], tightD[7])
    }

    /// Scale invariance: multiplying every grade by 40 (roughly NFL PPR -> NBA fantasy points)
    /// must not change how hard the board is. Absolute gaps are meaningless across sports —
    /// the live pool's average gap at the cutoff is 4.59 points in soccer and 130.83 in the NBA.
    func testDifficultyIsInvariantToTheSportsScale() {
        let nfl = keep4Puzzle()
        let scaled = Keep4Puzzle(id: "t", theme: "Test", sport: .nba,
                                 players: nfl.players.map {
            PlayerSeason(id: $0.id, name: $0.name, teamAbbr: $0.teamAbbr,
                         seasonYear: $0.seasonYear, stats: [], grade: $0.grade * 40)
        })
        for (a, b) in zip(nfl.players, scaled.players) {
            XCTAssertEqual(BotSolver.keep4Difficulty(of: a, in: nfl),
                           BotSolver.keep4Difficulty(of: b, in: scaled), accuracy: 0.001)
        }
    }
}

/// `LadderBot` decodes the `bots` table's snake_case JSON — mirrors `VersusChallenge`'s own
/// `CodingKeys` style — which means the repository must decode it with
/// `JSONDecoder.supabaseExplicitKeys`, NOT `.supabase`; see that decoder's doc comment.
final class LadderBotDecodingTests: XCTestCase {
    func testDecodesSnakeCaseJSON() throws {
        let json = """
        {"id": "bot-1", "name": "The Analyst", "avatar": "🧠", "tagline": "Reads the tape.",
         "base_skill": 0.72, "persona": "methodical"}
        """
        let bot = try JSONDecoder().decode(LadderBot.self, from: Data(json.utf8))
        XCTAssertEqual(bot.id, "bot-1")
        XCTAssertEqual(bot.name, "The Analyst")
        XCTAssertEqual(bot.avatar, "🧠")
        XCTAssertEqual(bot.baseSkill, 0.72, accuracy: 0.0001)
        XCTAssertEqual(bot.persona, "methodical")
    }
}
