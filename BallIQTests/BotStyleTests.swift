import XCTest
@testable import BallIQ

/// Style has to be a **gameplay** property, not a label. These pin the claims each style's
/// one-line description makes to the player — if a style stops behaving the way its own copy
/// says it does, that copy has become a lie and this goes red.
final class BotStyleTests: XCTestCase {

    private let easy = 0.05      // a gimme
    private let hard = 0.95      // a coin-flip call
    private let skill = 0.70

    private func p(_ style: BotStyle, _ difficulty: Double, progress: Double = 0.5) -> Double {
        BotSolver.hitProbability(skill: skill, difficulty: difficulty,
                                 style: style, progress: progress)
    }

    /// "Metronomic" is the baseline every other style reads against, so it must be the identity
    /// transform — otherwise the comparisons below measure nothing.
    func testConsistentIsTheIdentityBaseline() {
        for d in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(p(.consistent, d), pow(skill, d), accuracy: 1e-9)
        }
    }

    /// "Nails the obvious ones and guesses at everything close."
    ///
    /// Measured in the mid-hard band rather than at `difficulty == 1`. Every style converges on
    /// the raw skill floor at the extreme — `skill^1` is `skill` however the difficulty was
    /// reshaped, and `overeager` clamps there — so the top of the range is exactly where the
    /// styles are *least* distinguishable. The band that decides real boards is the middle.
    func testOvereagerKeepsGimmesAndCollapsesOnCloseCalls() {
        XCTAssertEqual(p(.overeager, easy), p(.consistent, easy), accuracy: 0.03,
                       "the gimmes should stay gimmes")
        let closeCall = 0.6
        XCTAssertLessThan(p(.overeager, closeCall), p(.consistent, closeCall) - 0.04,
                          "close calls should be materially worse than baseline")
        XCTAssertEqual(p(.overeager, 1.0), p(.consistent, 1.0), accuracy: 0.02,
                       "and both should bottom out at raw skill on the hardest call there is")
    }

    /// "Excellent when the numbers are clear, lost when they are close."
    func testMethodicalIsStrongerInTheMiddleAndNotOnTheHardest() {
        XCTAssertGreaterThan(p(.methodical, 0.5), p(.consistent, 0.5),
                             "the readable middle should be better than baseline")
        XCTAssertEqual(p(.methodical, 1.0), p(.consistent, 1.0), accuracy: 0.02,
                       "the genuinely close call should stay just as hard")
    }

    /// "Deadly on the obscure ones, overthinks the obvious." The one inversion in the set, and
    /// the reason `difficulty` is a transformable input at all.
    func testDeepCutsInvertsTheDifficultySignal() {
        XCTAssertGreaterThan(p(.deepCuts, hard), p(.consistent, hard),
                             "should beat baseline on the obscure calls")
        XCTAssertLessThan(p(.deepCuts, easy), p(.consistent, easy),
                          "and be worse than baseline on the obvious ones")
    }

    /// "Starts cold and gets stronger every card."
    func testSlowBurnRampsAcrossTheRun() {
        let start = p(.slowBurn, 0.6, progress: 0)
        let end = p(.slowBurn, 0.6, progress: 1)
        XCTAssertGreaterThan(end, start, "should be stronger at the end than the start")
        XCTAssertLessThan(start, p(.consistent, 0.6), "and start below baseline")
    }

    /// "Very nearly perfect — with the occasional inexplicable blank." The blink must be
    /// visible even on a decision that is otherwise certain.
    func testPrescientBlinksEvenOnACertainty() {
        XCTAssertLessThan(p(.prescient, 0), 1.0)
        XCTAssertEqual(p(.prescient, 0), 1 - BotStyle.prescient.blinkChance, accuracy: 1e-9)
    }

    /// The handicap styles carry is capped for a structural reason, not a taste one: at the top
    /// of the ladder the solver has already pushed `bot_skill` to 1.0, so anything a style
    /// subtracts there cannot be compensated for and the curve inverts. It did, at 0.06.
    func testHandicapsStaySmallEnoughToTuneAgainst() {
        XCTAssertLessThanOrEqual(BotStyle.prescient.blinkChance, 0.04)
        // A maxed slow-burn must still reach near-certainty by the end of a run.
        XCTAssertGreaterThan(BotStyle.slowBurn.skill(1.0, progress: 1.0), 0.99)
    }

    /// Every style must stay a probability for every input, including the extremes.
    func testProbabilitiesStayInRange() {
        for style in BotStyle.allCases {
            for d in stride(from: 0.0, through: 1.0, by: 0.25) {
                for prog in [0.0, 0.5, 1.0] {
                    for s in [0.0, 0.35, 1.0] {
                        let v = BotSolver.hitProbability(skill: s, difficulty: d,
                                                         style: style, progress: prog)
                        XCTAssertTrue((0...1).contains(v), "\(style) d=\(d) s=\(s) -> \(v)")
                    }
                }
            }
        }
    }

    // MARK: - The whole run, not just one decision

    /// The point of all of this: at identical skill on an identical board, two styles produce
    /// visibly different runs. If this fails, styles are decoration.
    func testStylesProduceDistinctRunsAtIdenticalSkill() {
        let puzzle = Self.board()
        var means: [BotStyle: Double] = [:]
        for style in BotStyle.allCases {
            let runs = (0..<400).map {
                BotSolver.playKeep4(puzzle, skill: 0.65, seed: UInt64($0 + 1),
                                    timeLimit: 120, style: style).performance
            }
            means[style] = runs.reduce(0, +) / Double(runs.count)
        }
        let spread = (means.values.max() ?? 0) - (means.values.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.04,
                             "styles at the same skill should be distinguishable by outcome; "
                             + "got \(means.mapValues { round($0 * 1000) / 1000 })")
    }

    /// Pace is half of what a style feels like — the rookie rushing, the archivist deliberating.
    func testPaceDiffersByStyleAndNeverRunsPastTheBuzzer() {
        let puzzle = Self.board()
        let limit: TimeInterval = 120
        var elapsed: [BotStyle: TimeInterval] = [:]
        for style in BotStyle.allCases {
            let run = BotSolver.playKeep4(puzzle, skill: 0.65, seed: 7,
                                          timeLimit: limit, style: style)
            elapsed[style] = run.elapsed
            XCTAssertLessThanOrEqual(run.elapsed, limit, "\(style) ran past the buzzer")
        }
        XCTAssertLessThan(elapsed[.overeager] ?? 0, elapsed[.methodical] ?? 0,
                          "the rookie should finish before the spreadsheet")
    }

    /// Style must not break seeding — a rung has to play out identically on every device.
    func testStyledRunsStaySeeded() {
        let puzzle = Self.board()
        for style in BotStyle.allCases {
            let a = BotSolver.playKeep4(puzzle, skill: 0.6, seed: 99, timeLimit: 120, style: style)
            let b = BotSolver.playKeep4(puzzle, skill: 0.6, seed: 99, timeLimit: 120, style: style)
            XCTAssertEqual(a, b, "\(style) is not reproducible from its seed")
        }
    }

    /// Grades spaced at ~3% of magnitude around the cutoff, which is where real boards actually
    /// sit (measured: 1.5%–4.8% at the keep/cut line) — so the difficulties land mid-range and
    /// the styles have room to differ.
    private static func board() -> Keep4Puzzle {
        let grades: [Double] = [118, 112, 106, 103, 100, 97, 91, 85]
        let players = grades.enumerated().map { i, g in
            PlayerSeason(id: "p\(i)", name: "P\(i)", teamAbbr: "TM",
                         seasonYear: 2000 + i, stats: [], grade: g)
        }
        return Keep4Puzzle(id: "style-fixture", theme: "Fixture", sport: .nfl, players: players)
    }
}
