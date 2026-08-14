import XCTest
@testable import BallIQ

/// Pins the ladder's difficulty model against the **real** `BotSolver`.
///
/// `tools/ingest/ladder.py` solves each rung's `bot_skill` by simulating a reference player
/// against the bot on the real board, and stores the win rate it achieved in
/// `ladder_rungs.target_win_rate`. That simulation is a Python re-implementation of
/// `BotSolver`'s policies — the same duplicate-and-pin arrangement `grade.py` and
/// `GradeFormula.swift` already live under. This is the pin: it replays each rung with the
/// Swift solver and fails if the two models disagree.
///
/// It also guards the two properties the curve exists to have, which the first seeding did not:
/// the ladder gets harder as you climb, and no rung is a board so obvious that the bot cannot
/// miss (`hitProbability = skill^difficulty` is 1.0 at difficulty 0 for *any* skill, so an easy
/// board makes a flawless bot — the reason rung 18 was once harder than rung 30).
///
/// Skips without the fixture, which is the normal state on a fresh checkout; regenerate it with
/// the dump in `tools/ingest/ladder.py`'s module docstring.
final class LadderCurveTests: XCTestCase {

    private static let fixturePath =
        "/private/tmp/claude-501/-Users-xanderevans-Documents-fantasy-app/098657bc-7222-4e9c-be21-f2ea6963ff83/scratchpad/ladder_fixture.json"

    private struct Row: Decodable {
        let rung: Rung
        let puzzle: Puzzle
        struct Rung: Decodable {
            let rung: Int, mode: String, sport: String
            let bot_skill: Double, is_boss: Bool
            let board_difficulty: Double?, target_win_rate: Double?
            /// The guarding character's playing style. Load-bearing for this pin: style changes
            /// the solver's policy, so measuring a rung with the wrong one measures nothing.
            let style: String?
        }
        struct Puzzle: Decodable { let id: String; let content: RawJSON }
    }

    /// Re-encodes an arbitrary JSON subtree so each rung's `content` can be decoded into
    /// whichever of the three puzzle models it actually is.
    private struct RawJSON: Decodable {
        let data: Data
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            data = try JSONEncoder().encode(try container.decode(AnyJSON.self))
        }
    }
    private enum AnyJSON: Codable {
        case null, bool(Bool), number(Double), string(String)
        case array([AnyJSON]), object([String: AnyJSON])
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([AnyJSON].self) { self = .array(v) }
            else { self = .object(try c.decode([String: AnyJSON].self)) }
        }
        func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    /// Matches `REFERENCE_PLAYER_SKILL` in tools/ingest/ladder.py. Changing one without the
    /// other is exactly what this test exists to catch.
    private let referencePlayerSkill = 0.75
    private let trials = 1_200

    private func rows() throws -> [Row] {
        guard let data = FileManager.default.contents(atPath: Self.fixturePath) else {
            throw XCTSkip("ladder fixture not present — see tools/ingest/ladder.py")
        }
        return try JSONDecoder().decode([Row].self, from: data)
    }

    /// One simulated duel: both sides run the same policy on the same board, ties to the player
    /// (`LadderOutcome.playerWon`).
    private func measuredWinRate(_ row: Row) throws -> Double {
        let plain = JSONDecoder()
        let mode = row.rung.mode
        var wins = 0
        for t in 0..<trials {
            let playerSeed = UInt64(t &* 2 &+ 1)
            let botSeed = UInt64(t &* 2 &+ 2)
            let player: Double, bot: Double
            // The reference player is deliberately `.consistent`: the player model is a
            // yardstick, not a character, and giving it a style would make the curve a claim
            // about one imagined personality rather than about the rung.
            let style = BotStyle(rawValue: row.rung.style ?? "consistent") ?? .consistent
            switch mode {
            case "keep4":
                let p = try plain.decode(Keep4Puzzle.self, from: row.puzzle.content.data)
                player = BotSolver.playKeep4(p, skill: referencePlayerSkill, seed: playerSeed, timeLimit: 60).performance
                bot = BotSolver.playKeep4(p, skill: row.rung.bot_skill, seed: botSeed, timeLimit: 60, style: style).performance
            case "grid":
                let p = try plain.decode(GridPuzzle.self, from: row.puzzle.content.data)
                player = BotSolver.playGrid(p, skill: referencePlayerSkill, seed: playerSeed, timeLimit: 60).performance
                bot = BotSolver.playGrid(p, skill: row.rung.bot_skill, seed: botSeed, timeLimit: 60, style: style).performance
            case "whoami":
                let p = try plain.decode(WhoAmIPuzzle.self, from: row.puzzle.content.data)
                player = BotSolver.playWhoAmI(p, skill: referencePlayerSkill, seed: playerSeed, timeLimit: 60).performance
                bot = BotSolver.playWhoAmI(p, skill: row.rung.bot_skill, seed: botSeed, timeLimit: 60, style: style).performance
            default:
                continue
            }
            if LadderOutcome.playerWon(playerScore: player, botScore: bot) { wins += 1 }
        }
        return Double(wins) / Double(trials)
    }

    /// The pin. A policy change in either language moves this and the test says which rung.
    func testSwiftSolverAgreesWithTheSeededTargets() throws {
        var worst = (rung: 0, delta: 0.0)
        for row in try rows() {
            guard let target = row.rung.target_win_rate else {
                XCTFail("rung \(row.rung.rung) has no target_win_rate — reseed with tools/ingest/ladder.py")
                continue
            }
            let measured = try measuredWinRate(row)
            let delta = abs(measured - target)
            if delta > worst.delta { worst = (row.rung.rung, delta) }
            // 0.10 absorbs Monte Carlo noise at this trial count without absorbing a real
            // policy divergence, which moves a rung by far more than that.
            XCTAssertEqual(measured, target, accuracy: 0.10,
                           "rung \(row.rung.rung) (\(row.rung.mode)): Swift measured \(measured), "
                           + "tools/ingest/ladder.py seeded \(target). The two difficulty models "
                           + "have diverged.")
        }
        print("LADDER_PIN: worst rung \(worst.rung), delta \(String(format: "%.3f", worst.delta))")
    }

    /// No rung may sit on a board so obvious the bot cannot miss it.
    func testNoRungIsBelowTheDifficultyFloor() throws {
        for row in try rows() {
            guard let d = row.rung.board_difficulty else { continue }
            XCTAssertGreaterThanOrEqual(
                d, 0.18,
                "rung \(row.rung.rung) sits on a board of difficulty \(d). Below the floor both "
                + "sides score at ceiling and `bot_skill` stops meaning anything — this is how "
                + "rung 18 ended up harder than rung 30.")
        }
    }

    /// The ladder must get harder as you climb. Compared over a window rather than adjacently:
    /// Who Am I?'s coarse 7-value comparable floors its win rate around 0.73, so a whoami rung
    /// in the mid band is legitimately a small step sideways — but five rungs later must be a
    /// real step down.
    func testTheCurveDescendsAcrossTheLadder() throws {
        let byRung = try rows().sorted { $0.rung.rung < $1.rung.rung }
        let targets = byRung.compactMap(\.rung.target_win_rate)
        guard targets.count >= 10 else { throw XCTSkip("too few rungs seeded") }
        for i in 0..<(targets.count - 5) {
            XCTAssertGreaterThan(
                targets[i], targets[i + 5],
                "rung \(byRung[i].rung.rung) (\(targets[i])) is not harder than rung "
                + "\(byRung[i + 5].rung.rung) (\(targets[i + 5]))")
        }
        XCTAssertGreaterThan(targets.first ?? 0, 0.80, "the first rung has to be enterable")
        XCTAssertLessThan(targets.last ?? 1, 0.40, "the last rung has to actually be a wall")
    }
}
