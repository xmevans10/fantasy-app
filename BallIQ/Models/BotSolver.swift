import Foundation

/// One decision the bot made, on the clock — this is what lets a bot's run be replayed
/// alongside the player in real time, which is the whole point (a live-feeling opponent with
/// zero realtime infrastructure).
struct BotBeat: Equatable {
    /// Seconds from the start of the run.
    let at: TimeInterval
    /// Which decision this was, in the format's own indexing (card index / cell index /
    /// clue index).
    let index: Int
    let correct: Bool
}

/// A completed bot run, in the same comparable every human run produces.
struct BotRun: Equatable {
    /// 0...1 — drops straight into the same comparable as a human duel score.
    let performance: Double
    let correct: Int
    let outOf: Int
    let beats: [BotBeat]
    /// Total wall time the bot "took", <= timeLimit.
    var elapsed: TimeInterval { beats.last?.at ?? 0 }
}

/// Bots play by making a real, skill-limited decision on every real card/cell/clue rather than
/// rolling a single number for the whole run — see HANDOFF-multiplayer.md's "Bots as
/// skill-limited solvers". That is what lets a bot's `beats` be replayed alongside a human's
/// live progress with no server round trip: the run is just data, computed once, entirely
/// on-device.
enum BotSolver {
    /// How many decisions a Keep4 bot is allowed to keep — same cap `Keep4GameView.pileLimit`
    /// enforces on a human, so a bot's run is comparable rather than an easier game.
    private static let keep4PileLimit = 4

    /// Probability the bot gets one decision right.
    ///
    /// `skill^difficulty`: at `difficulty == 0` (a gimme) this is 1 for any skill > 0, so even a
    /// weak bot reliably nails the obvious calls; at `difficulty == 1` (the hardest call in the
    /// format) it reduces to exactly `skill`. Between those two anchors it interpolates smoothly
    /// and stays monotonic in both directions — increasing in skill (since `skill < 1` implies
    /// `d/d(skill) skill^difficulty > 0`), decreasing in difficulty (since `ln(skill) < 0`).
    /// `skill` is floored above 0 so `pow` never has to evaluate `0^0`.
    static func hitProbability(skill: Double, difficulty: Double) -> Double {
        let s = min(max(skill, 0.0001), 1.0)
        let d = min(max(difficulty, 0.0), 1.0)
        return pow(s, d)
    }

    // MARK: - Keep4

    /// Keep/cut all 8 cards, respecting the same 4-keep/4-cut cap the human plays under.
    ///
    /// Each card's difficulty is how close its `grade` sits to the puzzle's own keep/cut cutoff
    /// (the midpoint between the 4th- and 5th-best grade), normalized against the puzzle's own
    /// grade spread so the same policy works whether the sport's grades run in the tens or the
    /// thousands. A card at the cutoff is the hardest call there is; one far from it is a gimme.
    ///
    /// A per-card roll can land the bot on 5 keeps and 3 cuts (or any other split) before the
    /// cap is enforced. Rather than reject and re-roll (which would bias the RNG stream and
    /// complicate reproducibility), the least-confident decisions — lowest `hitProbability`,
    /// i.e. the closest calls — are flipped until the piles land on 4/4. That is the correct
    /// place to spend the "give up a decision" budget: a bot forced to change its mind should
    /// give up the calls it was least sure of, not an arbitrary one.
    static func playKeep4(_ puzzle: Keep4Puzzle, skill: Double, seed: UInt64,
                         timeLimit: TimeInterval) -> BotRun {
        guard !puzzle.players.isEmpty else { return BotRun(performance: 0, correct: 0, outOf: 0, beats: []) }
        var gen = SeededGenerator(seed: seed)
        let cards = keep4Decisions(puzzle, skill: skill, gen: &gen)
        let outcomes = cards.map { $0.decision == $0.correctVerdict }
        let beats = paceBeats(outcomes: outcomes, skill: skill, timeLimit: timeLimit, gen: &gen)
        let correct = outcomes.filter { $0 }.count
        return BotRun(performance: Double(correct) / Double(puzzle.players.count),
                     correct: correct, outOf: puzzle.players.count, beats: beats)
    }

    /// A relative gap this large or larger is treated as an obvious call.
    ///
    /// Calibrated against the live Keep4 pool (2026-08-13, 185 released boards): the gap right
    /// at the keep/cut line averages 1.5%–4.8% of the board's grade magnitude depending on
    /// sport, spanning 0.03% to 44%. So 10% is comfortably outside the range where a human is
    /// actually weighing two seasons against each other, and the interesting band lands in the
    /// middle of the 0...1 difficulty scale instead of pinned at one end.
    static let keep4ObviousRelativeGap = 0.10

    /// How hard one keep/cut call is, from the puzzle's **own scoring metric** — `grade`, which
    /// is real fantasy points (PPR, era-adjusted, or the author's custom rule; see
    /// `GradeFormula`). Whatever ranks the puzzle is what decides how obvious it is, because it
    /// is literally the thing the player is being asked to estimate.
    ///
    /// Two normalization choices, both load-bearing:
    ///
    /// * **Distance from the cutoff**, not from the field. Keep4 is a threshold decision (top 4
    ///   vs bottom 4), so a card's difficulty is how near it sits to the 4th/5th boundary.
    /// * **Scaled by the board's own grade magnitude**, not by its spread. Scaling by spread —
    ///   what this did until 2026-08-13 — rescales every board to have the same hardest card,
    ///   so no board can ever be *globally* easy or hard, and the measured intrinsic difficulty
    ///   of the whole live pool collapsed into 0.47...0.74. Magnitude also makes sports
    ///   comparable where absolutes cannot: the average gap at the cutoff is 4.59 points in
    ///   soccer and 130.83 in the NBA, a 28x scale difference that says nothing about how hard
    ///   the call is — but as a fraction they are 2.2% and 1.5%, which does.
    ///
    /// Magnitude is the mean absolute grade rather than the cutoff itself, so a board whose
    /// cutoff sits near zero (reachable on single-game grains, where a bad line can be negative)
    /// doesn't divide by ~0 and report every card as a coin flip.
    static func keep4Difficulty(of player: PlayerSeason, in puzzle: Keep4Puzzle) -> Double {
        let grades = puzzle.players.map(\.grade)
        guard !grades.isEmpty else { return 0.5 }
        let byGradeDesc = grades.sorted(by: >)
        let cutoff = byGradeDesc.count >= 5
            ? (byGradeDesc[3] + byGradeDesc[4]) / 2
            : grades.reduce(0, +) / Double(grades.count)
        let magnitude = grades.map(abs).reduce(0, +) / Double(grades.count)
        guard magnitude > 0.0001 else { return 1 }
        let relativeGap = abs(player.grade - cutoff) / magnitude
        return 1 - min(1, relativeGap / keep4ObviousRelativeGap)
    }

    /// Exposed (not private) purely so `BotSolverTests` can assert the 4/4 split holds at every
    /// skill and seed — `BotRun` itself only ever reports correctness, never which pile a
    /// decision landed in, because no real caller needs that.
    static func keep4PileCounts(_ puzzle: Keep4Puzzle, skill: Double, seed: UInt64) -> (keep: Int, cut: Int) {
        guard !puzzle.players.isEmpty else { return (0, 0) }
        var gen = SeededGenerator(seed: seed)
        let cards = keep4Decisions(puzzle, skill: skill, gen: &gen)
        return (cards.filter { $0.decision == .keep }.count, cards.filter { $0.decision == .cut }.count)
    }

    /// One roll per card (in the human's own serve order, so beat index N stays the same card
    /// for both), then the 4/4 cap is enforced by flipping the least-confident decisions —
    /// lowest `hitProbability`, i.e. the closest calls — until the piles land right. That is the
    /// correct place to spend the "give up a decision" budget: a bot forced to change its mind
    /// should give up the calls it was least sure of, not an arbitrary one. Rejecting and
    /// re-rolling instead would bias the RNG stream and complicate reproducibility.
    ///
    /// Difficulty per card comes from `keep4Difficulty(of:in:)` — see that method for why the
    /// puzzle's *scoring metric* is the ground truth and how it is scaled.
    private static func keep4Decisions(_ puzzle: Keep4Puzzle, skill: Double,
                                       gen: inout SeededGenerator) -> [BotSolverKeep4Card] {
        let order = Keep4GameView.blindOrder(for: puzzle)
        let correctKeepIDs = puzzle.correctKeepIDs

        var cards: [BotSolverKeep4Card] = order.map { player in
            let difficulty = Self.keep4Difficulty(of: player, in: puzzle)
            let p = hitProbability(skill: skill, difficulty: difficulty)
            let correctVerdict: Pile = correctKeepIDs.contains(player.id) ? .keep : .cut
            let hit = Double.random(in: 0..<1, using: &gen) < p
            return BotSolverKeep4Card(p: p, decision: hit ? correctVerdict : correctVerdict.flipped,
                                      correctVerdict: correctVerdict)
        }

        let keepCount = cards.filter { $0.decision == .keep }.count
        if keepCount > keep4PileLimit {
            flipLeastConfident(&cards, from: .keep, count: keepCount - keep4PileLimit)
        } else if keepCount < keep4PileLimit {
            flipLeastConfident(&cards, from: .cut, count: keep4PileLimit - keepCount)
        }
        return cards
    }

    /// Moves `count` cards currently decided as `pile` to the other pile, picking the ones with
    /// the lowest `hitProbability` first (the closest calls, in serve order for ties).
    private static func flipLeastConfident(_ cards: inout [BotSolverKeep4Card], from pile: Pile, count: Int) {
        let candidates = cards.indices
            .filter { cards[$0].decision == pile }
            .sorted { cards[$0].p < cards[$1].p }
        for idx in candidates.prefix(count) {
            cards[idx].decision = cards[idx].decision.flipped
        }
    }

    // MARK: - Grid

    /// One independent decision per cell (no pile cap, unlike Keep4) — difficulty comes straight
    /// from the board's own `rarityStars`, already the difficulty signal the generator baked in.
    static func playGrid(_ puzzle: GridPuzzle, skill: Double, seed: UInt64,
                        timeLimit: TimeInterval) -> BotRun {
        guard !puzzle.cells.isEmpty else { return BotRun(performance: 0, correct: 0, outOf: 0, beats: []) }
        var gen = SeededGenerator(seed: seed)
        let outcomes: [Bool] = puzzle.cells.map { cell in
            let difficulty = min(max(Double(cell.rarityStars - 1) / 4.0, 0), 1)
            let p = hitProbability(skill: skill, difficulty: difficulty)
            return Double.random(in: 0..<1, using: &gen) < p
        }
        let beats = paceBeats(outcomes: outcomes, skill: skill, timeLimit: timeLimit, gen: &gen)
        let correct = outcomes.filter { $0 }.count
        return BotRun(performance: Double(correct) / Double(puzzle.cells.count),
                     correct: correct, outOf: puzzle.cells.count, beats: beats)
    }

    // MARK: - Who Am I?

    /// Solves at clue N, where N is drawn by skill rather than fixed: at each revealed clue the
    /// bot "attempts" the answer with `hitProbability`, difficulty falling from 1 (clue 1, the
    /// least revealing) to 0 (the last clue) as more information comes in — the same axis
    /// `WhoAmIScoring` already uses to price a solve. A skilled bot tends to land the roll on an
    /// early, high-difficulty clue; a weak one grinds toward the end and may never land it at
    /// all, matching the brief's "fails outright" case. Wrong guesses aren't modeled (the bot
    /// either solves on a clue or waits for the next one) — the format's real payoff axis is
    /// which clue you solved on, not how many free-text guesses you burned getting there, and
    /// `WhoAmIScoring.score` already handles a `wrongGuesses: 0` result correctly.
    static func playWhoAmI(_ puzzle: WhoAmIPuzzle, skill: Double, seed: UInt64,
                          timeLimit: TimeInterval) -> BotRun {
        let clueCount = puzzle.clues.count
        guard clueCount > 0 else { return BotRun(performance: 0, correct: 0, outOf: 1, beats: []) }
        var gen = SeededGenerator(seed: seed)

        var solved = false
        var cluesUsed = clueCount
        for i in 0..<clueCount {
            let difficulty = clueCount > 1 ? 1 - Double(i) / Double(clueCount - 1) : 0
            let p = hitProbability(skill: skill, difficulty: difficulty)
            if Double.random(in: 0..<1, using: &gen) < p {
                solved = true
                cluesUsed = i + 1
                break
            }
        }

        let revealed = solved ? cluesUsed : clueCount
        let outcomes = (0..<revealed).map { $0 == cluesUsed - 1 && solved }
        let beats = paceBeats(outcomes: outcomes, skill: skill, timeLimit: timeLimit, gen: &gen)
        let result = WhoAmIScoring.score(cluesUsed: cluesUsed, wrongGuesses: 0, solved: solved,
                                         difficulty: puzzle.difficulty)
        return BotRun(performance: result.performance, correct: solved ? 1 : 0, outOf: 1, beats: beats)
    }

    // MARK: - Pacing

    /// Spaces `outcomes.count` decisions across the clock. Random per-decision weights (drawn
    /// from the same seeded stream, so the whole run stays reproducible) avoid a metronomic
    /// beat cadence, then get scaled so their sum lands on `timeLimit * pacingFraction(skill)` —
    /// always strictly under `timeLimit`, so `elapsed` never needs a separate clamp.
    private static func paceBeats(outcomes: [Bool], skill: Double, timeLimit: TimeInterval,
                                  gen: inout SeededGenerator) -> [BotBeat] {
        guard !outcomes.isEmpty else { return [] }
        let weights = outcomes.indices.map { _ in Double.random(in: 0.6...1.4, using: &gen) }
        let weightSum = weights.reduce(0, +)
        let totalDuration = timeLimit * pacingFraction(skill: skill)
        var elapsed: TimeInterval = 0
        return outcomes.enumerated().map { index, correct in
            elapsed += totalDuration * (weights[index] / weightSum)
            return BotBeat(at: elapsed, index: index, correct: correct)
        }
    }

    /// Fraction of the clock a bot at this skill uses end to end. A boss rung has to *feel*
    /// like a boss: a 0.95 bot finishing with 60% of the clock to spare reads as a machine that
    /// was never in danger, while a 0.35 bot grinding to the buzzer reads as exactly the beatable
    /// opponent it is. Clamped well short of `[0, 1]` at both ends so no bot ever looks
    /// instantaneous or ever blows through the buzzer.
    private static func pacingFraction(skill: Double) -> Double {
        max(0.35, min(0.97, 1.05 - skill * 0.65))
    }
}

/// Kept file-private to `BotSolver.swift` (the Keep4 flip helper needs a named type to mutate
/// through an `inout` array; an anonymous local struct can't be referenced from a sibling
/// static function's parameter list).
private struct BotSolverKeep4Card {
    let p: Double
    var decision: Pile
    let correctVerdict: Pile
}

private extension Pile {
    var flipped: Pile { self == .keep ? .cut : .keep }
}
