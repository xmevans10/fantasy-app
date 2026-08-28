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
/// **One fixture entry per BOARD, not per rung.** A rung owns a pool of boards now
/// (`ladder_rung_boards`), and the pool is only difficulty-homogeneous if *every* board in it was
/// verified — a pool where board 0 lands the curve and board 4 is half as hard is a rung that
/// means something different depending on which one you drew, which is exactly the failure the
/// pool's ±0.04 difficulty and ±0.08 win-rate tolerances exist to prevent. So this replays all of
/// them.
///
/// Skips without the fixture, which is the normal state on a fresh checkout. Regenerate with:
///
///     set -a && . tools/ingest/.env && set +a && python -m tools.ingest.ladder --fixture
///
/// (The path below was once a per-session scratchpad directory. That session ended, the file went
/// with it, and the pin silently skipped on every run afterwards while still reporting green —
/// so it now lives one level up, where it outlives any single session.)
final class LadderCurveTests: XCTestCase {

    private static let fixturePath =
        "/private/tmp/claude-501/-Users-xanderevans-Documents-fantasy-app/ladder_fixture.json"

    private struct Row: Decodable {
        let rung: Rung
        let puzzle: Puzzle
        struct Rung: Decodable {
            let rung: Int, mode: String, sport: String
            let bot_skill: Double, is_boss: Bool
            let board_difficulty: Double?, target_win_rate: Double?
            /// Which board of this rung's pool. 0 is the rung's own `puzzle_id`.
            let ordinal: Int?
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
            throw XCTSkip("ladder fixture not present, see tools/ingest/ladder.py")
        }
        return try JSONDecoder().decode([Row].self, from: data)
    }

    /// One simulated duel: both sides run the same policy on the same board, ties to the player
    /// (`LadderOutcome.playerWon`).
    private func measuredWinRate(_ row: Row) throws -> Double {
        let plain = JSONDecoder()
        let mode = row.rung.mode
        // Both sides run on the same clock, and only the FRACTION each uses feeds the speed term
        // — so this needs to match tools/ingest/ladder.py's model, not any particular rung's real
        // `time_limit_seconds`.
        let limit: TimeInterval = 60
        var wins = 0
        for t in 0..<trials {
            let playerSeed = UInt64(t &* 2 &+ 1)
            let botSeed = UInt64(t &* 2 &+ 2)
            let player: BotRun, bot: BotRun
            // The reference player is deliberately `.consistent`: the player model is a
            // yardstick, not a character, and giving it a style would make the curve a claim
            // about one imagined personality rather than about the rung.
            let style = BotStyle(rawValue: row.rung.style ?? "consistent") ?? .consistent
            switch mode {
            case "keep4":
                let p = try plain.decode(Keep4Puzzle.self, from: row.puzzle.content.data)
                player = BotSolver.playKeep4(p, skill: referencePlayerSkill, seed: playerSeed, timeLimit: limit)
                bot = BotSolver.playKeep4(p, skill: row.rung.bot_skill, seed: botSeed, timeLimit: limit, style: style)
            case "grid":
                let p = try plain.decode(GridPuzzle.self, from: row.puzzle.content.data)
                player = BotSolver.playGrid(p, skill: referencePlayerSkill, seed: playerSeed, timeLimit: limit)
                bot = BotSolver.playGrid(p, skill: row.rung.bot_skill, seed: botSeed, timeLimit: limit, style: style)
            case "whoami":
                let p = try plain.decode(WhoAmIPuzzle.self, from: row.puzzle.content.data)
                player = BotSolver.playWhoAmI(p, skill: referencePlayerSkill, seed: playerSeed, timeLimit: limit)
                bot = BotSolver.playWhoAmI(p, skill: row.rung.bot_skill, seed: botSeed, timeLimit: limit, style: style)
            default:
                continue
            }
            // Speed is part of the comparable now, so the pin has to measure the same thing the
            // seeder solves for — the reference player is paced by the same model as the bot,
            // which is the symmetry the accuracy model already assumes.
            if LadderOutcome.playerWon(playerScore: player.performance, botScore: bot.performance,
                                       playerElapsed: player.elapsed, botElapsed: bot.elapsed,
                                       limit: limit) { wins += 1 }
        }
        return Double(wins) / Double(trials)
    }

    /// The pin. A policy change in either language moves this and the test says which board.
    ///
    /// Every board of every pool is replayed, not just each rung's ordinal 0: a pool board is
    /// selected on a *simulated* win rate, so an unverified one is a rung quietly promising a
    /// difficulty it doesn't deliver.
    func testSwiftSolverAgreesWithTheSeededTargets() throws {
        var worst = (rung: 0, ordinal: 0, delta: 0.0)
        var boards = 0
        for row in try rows() {
            guard let target = row.rung.target_win_rate else {
                XCTFail("rung \(row.rung.rung) has no target_win_rate, reseed with tools/ingest/ladder.py")
                continue
            }
            let measured = try measuredWinRate(row)
            let delta = abs(measured - target)
            boards += 1
            if delta > worst.delta { worst = (row.rung.rung, row.rung.ordinal ?? 0, delta) }
            // 0.10 absorbs Monte Carlo noise at this trial count without absorbing a real
            // policy divergence, which moves a rung by far more than that.
            XCTAssertEqual(measured, target, accuracy: 0.10,
                           "rung \(row.rung.rung) board \(row.rung.ordinal ?? 0) "
                           + "(\(row.rung.mode), \(row.puzzle.id)): Swift measured \(measured), "
                           + "tools/ingest/ladder.py seeded \(target). The two difficulty models "
                           + "have diverged, or this board does not belong in the pool.")
        }
        print("LADDER_PIN: \(boards) boards, worst rung \(worst.rung) ordinal \(worst.ordinal), "
              + "delta \(String(format: "%.3f", worst.delta))")
    }

    /// No board of any pool may be so obvious the bot cannot miss it.
    func testNoRungIsBelowTheDifficultyFloor() throws {
        for row in try rows() {
            guard let d = row.rung.board_difficulty, d > 0 else { continue }
            XCTAssertGreaterThanOrEqual(
                d, 0.18,
                "rung \(row.rung.rung) board \(row.rung.ordinal ?? 0) (\(row.puzzle.id)) has "
                + "difficulty \(d). Below the floor both sides score at ceiling and `bot_skill` "
                + "stops meaning anything, this is how rung 18 ended up harder than rung 30.")
        }
    }

    /// A pool has to be difficulty-HOMOGENEOUS or the rung is a different rung depending on which
    /// board you drew — the promise `ladder_rungs.board_difficulty` makes to the player.
    func testEachPoolIsDifficultyHomogeneous() throws {
        let byRung = Dictionary(grouping: try rows(), by: \.rung.rung)
        for (rung, boards) in byRung.sorted(by: { $0.key < $1.key }) {
            let ds = boards.compactMap(\.rung.board_difficulty).filter { $0 > 0 }
            guard let lo = ds.min(), let hi = ds.max() else { continue }
            // Twice `POOL_DIFFICULTY_TOLERANCE` in tools/ingest/ladder.py: every board sits within
            // ±0.04 of the rung's own difficulty, so the widest legal spread is 0.08.
            XCTAssertLessThanOrEqual(
                hi - lo, 0.08 + 1e-9,
                "rung \(rung)'s pool spans difficulty \(lo)...\(hi) over \(ds.count) boards. "
                + "A rung's difficulty is a promise; this one keeps it or breaks it depending on "
                + "which board the player drew.")
        }
    }

    /// A rung the player can replay on the board they just solved is the bug this whole feature
    /// exists to fix, so "the pool is deep enough to be a pool" is worth asserting outright.
    func testEveryRungHasMoreThanOneBoard() throws {
        let byRung = Dictionary(grouping: try rows(), by: \.rung.rung)
        let thin = byRung.filter { $0.value.count < 2 }.keys.sorted()
        XCTAssertTrue(thin.isEmpty,
                      "rung(s) \(thin) have a single board, losing and retrying serves the "
                      + "identical board with the answers already known. Deepen the released pool "
                      + "(tools.ingest.main --grid <sport> --grid-days N) and re-run "
                      + "tools.ingest.ladder --upsert.")
    }

    /// The ladder must get harder as you climb. Compared over a window rather than adjacently:
    /// Who Am I?'s coarse 7-value comparable floors its win rate around 0.73, so a whoami rung
    /// in the mid band is legitimately a small step sideways — but five rungs later must be a
    /// real step down.
    func testTheCurveDescendsAcrossTheLadder() throws {
        // One entry per RUNG. The fixture now holds one row per board, so comparing raw rows five
        // apart would compare a rung against itself and pass no matter what the curve did.
        //
        // Bosses are excluded. Every tenth rung takes a deliberate skill bump — it is *supposed*
        // to be harder than the trend line — so comparing a boss against a normal rung five later
        // measures the bump, not the curve, and fails on a ladder that is behaving correctly
        // (rung 20 at 0.403 against rung 25 at 0.414). The property worth guarding is that the
        // baseline descends; the spikes are a separate promise.
        let byRung = try rows()
            .filter { ($0.rung.ordinal ?? 0) == 0 && !$0.rung.is_boss }
            .sorted { $0.rung.rung < $1.rung.rung }
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

// MARK: - The ladder's speed comparison after M25

/// `LadderOutcome.adjusted` stopped carrying its own copy of the speed formula and now delegates
/// to `SpeedMultiplier`. These pin what that delegation must not have changed — the ladder is the
/// one place speed still decides a *result* (who won the rung), rather than only points.
final class LadderOutcomeSpeedTests: XCTestCase {

    /// The two must agree exactly. If they drift, a rung's simulated difficulty (solved in
    /// `tools/ingest/ladder.py` against the same formula) stops describing the rung a player
    /// actually meets — the bot would be calibrated for a game nobody is playing.
    func testLadderOutcomeAndSpeedMultiplierAgree() {
        for elapsed in stride(from: 0.0, through: 240.0, by: 20.0) {
            XCTAssertEqual(LadderOutcome.adjusted(score: 0.7, elapsed: elapsed, limit: 120),
                           SpeedMultiplier.adjusted(score: 0.7, elapsed: elapsed, par: 120),
                           accuracy: 1e-12, "diverged at elapsed \(elapsed)")
        }
    }

    /// The property the whole mechanic rests on, asserted where it actually decides a win rather
    /// than only points: a faster run cannot beat a better one.
    func testBeingFasterDoesNotBeatBeingRight() {
        // 0.5 instantly vs 0.75 taking the full par.
        XCTAssertFalse(LadderOutcome.playerWon(playerScore: 0.5, botScore: 0.75,
                                               playerElapsed: 0.1, botElapsed: 120, limit: 120),
                       "a 0.5 finished instantly must not beat a 0.75")
    }

    /// Speed is allowed to separate two players who played the board equally well — that is the
    /// entire reason it survived the timer removal.
    func testAmongEqualScoresTheFasterSideTakesIt() {
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.75, botScore: 0.75,
                                              playerElapsed: 20, botElapsed: 100, limit: 120))
        XCTAssertFalse(LadderOutcome.playerWon(playerScore: 0.75, botScore: 0.75,
                                               playerElapsed: 100, botElapsed: 20, limit: 120))
    }

    /// A rung played with no timing data must still resolve, and must fall back to pure accuracy
    /// with ties going to the player — the documented degradation, and the path an offline or
    /// restored run takes.
    func testWithoutTimingItDegradesToAccuracyWithTiesToThePlayer() {
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.6, botScore: 0.6))
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.61, botScore: 0.6))
        XCTAssertFalse(LadderOutcome.playerWon(playerScore: 0.59, botScore: 0.6))
    }

    /// Taking longer than par is not a loss condition — it only stops paying. A rung must stay
    /// winnable by someone slow who was simply better.
    func testAWinIsStillPossibleArbitrarilyPastPar() {
        XCTAssertTrue(LadderOutcome.playerWon(playerScore: 0.9, botScore: 0.5,
                                              playerElapsed: 6000, botElapsed: 30, limit: 120),
                      "ten minutes late and still clearly better must still win the rung")
    }
}
