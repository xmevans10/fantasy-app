import Foundation

/// A bot's Puzzle Blitz run — the ladder's comparable, now that a rung is a blitz rather than a
/// single board.
///
/// ## Why the ladder moved to one mode
///
/// Every per-format rung was fighting its own floor. Keep4 forces a 4/4 split, so even a
/// deliberately bad sorter scores about half and no `bot_skill` could take the player's win rate
/// below ~0.27. Who Am I? scores on a 7-value clue ladder that saturates at a clue-1 solve, so a
/// *perfect* bot still lost ~75% of duels and the format had to be capped below rung 18. Two
/// formats, two different unreachable ends, and a curve that could not descend through both.
///
/// Blitz dissolves both, and not by accident:
///
/// * **`BlitzScoring.surplus` rebases every board so chance is worth exactly zero.** That is
///   precisely the keep4 floor, priced out at the source rather than tuned around.
/// * **A run aggregates several boards**, so no single format's scoring shape dominates the
///   comparable and one lucky clue-1 solve stops deciding a rung.
/// * **The clock gates whether a NEW board is served**, so speed is paid for by getting through
///   more boards. Blitz deliberately carries no `SpeedMultiplier` on top ("finishing sooner
///   already buys you another board — pricing that second twice"), which is also why the ladder
///   no longer needs a speed term in its own comparable.
///
/// Measured over real boards before any of this was built: sweeping bot skill 0.05 → 1.0 against
/// the reference player, a 180s blitz spans a **1.000 → 0.011** win rate where keep4 alone could
/// not get below 0.27. The lever works again.
///
/// ## Durations are a variance dial, not just flavour
///
/// A short run is a coin flip and a long one is a measurement. At 60s a weak side completes no
/// board at all — keep4's par is 120s and a weak side spends ~0.97 of par — so a one-minute run
/// collapses into a single-board duel and floors back around 0.28. Long runs shrink the spread,
/// which is exactly what a boss wants: a boss should be beaten by knowing more, not by drawing
/// well. See `LadderBlitz.duration(forRung:)`.
struct BlitzBotRun: Equatable {
    /// Every board the bot finished, in order. The boards it never reached are simply absent —
    /// running out of clock means playing fewer puzzles, never losing one already solved.
    let rounds: [BlitzRoundResult]
    /// `BlitzScoring.total` over `rounds` — the number the duel is decided on.
    let points: Int
    /// Wall-clock seconds spent, always <= the run's duration.
    let elapsed: TimeInterval

    var boardsPlayed: Int { rounds.count }
}

extension BotSolver {

    /// Plays a blitz run over a **given** board sequence.
    ///
    /// The sequence is passed in rather than drawn here, and that is the fairness rule: a ladder
    /// duel hands the bot and the player the same seeded sequence, so the two are answering the
    /// same questions and only how far each gets — and how much of each board they get right —
    /// separates them. (Arcade blitz keeps its genuinely random draw; determinism belongs to
    /// shared contests, per BALLIQ_SPEC §1 theme 4.)
    ///
    /// Each board costs `par × pacingFraction(skill) × style.paceMultiplier × spread` seconds,
    /// the same pacing model `paceBeats` uses, and a board is only started if it fits in what is
    /// left — mirroring `BlitzSession`, where the clock gates the *next* board.
    static func playBlitz(boards: [BlitzBoard], skill: Double, seed: UInt64,
                          duration: TimeInterval, style: BotStyle = .consistent,
                          knowledge: BotKnowledge = .neutral) -> BlitzBotRun {
        var gen = SeededGenerator(seed: seed)
        var remaining = duration
        var elapsed: TimeInterval = 0
        var rounds: [BlitzRoundResult] = []

        for (index, board) in boards.enumerated() {
            let par = board.format.parSeconds
            let spread = Double.random(in: (1 - paceVariance)...(1 + paceVariance), using: &gen)
            let spend = par * pacingFraction(skill: skill) * style.paceMultiplier * spread
            // The clock gates whether a NEW board starts and never reaches into one in flight —
            // the rule `BlitzSession.canServeAnother` states. A bot that cannot fit the next
            // board simply stops, exactly as a player's run ends.
            guard spend <= remaining else { break }

            // Per-board seed so a board's solve is reproducible on its own, independent of how
            // many boards came before it. Deriving it from the index rather than consuming the
            // run's generator keeps a board's outcome stable when the pacing draw changes.
            let boardSeed = seed &+ UInt64(index &+ 1) &* 0x9E3779B97F4A7C15
            let performance = solve(board, skill: skill, seed: boardSeed, timeLimit: spend,
                                   style: style, knowledge: knowledge, gen: &gen)

            remaining -= spend
            elapsed += spend
            rounds.append(BlitzRoundResult(format: board.format, sport: board.sport,
                                           puzzleID: board.puzzleID,
                                           performance: performance,
                                           cleared: performance > board.format.chanceFloor,
                                           elapsed: spend))
        }
        return BlitzBotRun(rounds: rounds, points: BlitzScoring.total(rounds), elapsed: elapsed)
    }

    /// One board's `performance`, routed to the format's existing policy.
    ///
    /// Three of the four reuse the very solver a single-board duel runs, so a bot is the same
    /// opponent inside a blitz as outside one and nothing about its difficulty model forks.
    private static func solve(_ board: BlitzBoard, skill: Double, seed: UInt64,
                              timeLimit: TimeInterval, style: BotStyle,
                              knowledge: BotKnowledge,
                              gen: inout SeededGenerator) -> Double {
        switch board {
        case .keep4(let p):
            return playKeep4(p, skill: skill, seed: seed, timeLimit: timeLimit,
                             style: style, knowledge: knowledge).performance
        case .whoami(let p):
            return playWhoAmI(p, skill: skill, seed: seed, timeLimit: timeLimit,
                              style: style, knowledge: knowledge).performance
        case .journeyman(let p):
            return playJourneyman(p, skill: skill, seed: seed, timeLimit: timeLimit,
                                  style: style, knowledge: knowledge).performance
        case .overunder(let round, let sport):
            // Over/Under is the one format with no multi-decision run to average, so it is
            // scored here rather than through a `play*`: one call, right or wrong.
            let p = hitProbability(skill: skill, difficulty: overUnderDifficulty(round),
                                   style: style, knowledge: knowledge,
                                   context: DecisionContext(sport: sport,
                                                            year: round.player.seasonYear))
            return Double.random(in: 0..<1, using: &gen) < p ? 1 : 0
        }
    }

    /// A relative gap this large or larger makes an over/under call obvious. The same shape and
    /// the same reasoning as `keep4ObviousRelativeGap`: distance from the line, scaled by the
    /// stat's own magnitude so a 12-yard gap on a 1,600-yard season and a 0.4 gap on a 5.0 ERA
    /// are read as the same kind of call.
    static let overUnderObviousRelativeGap = 0.25

    /// How hard one over/under call is, from the only signal the round has — how close the real
    /// value sits to the threshold it is being compared against.
    ///
    /// Scaled by the threshold's magnitude rather than by the pool's spread, for the reason
    /// `keep4Difficulty` documents: a per-board rescale would make every round equally hard and
    /// leave the format unable to be easy or hard at all. A threshold at ~0 (reachable on rate
    /// stats) falls back to a coin flip rather than dividing by nothing.
    static func overUnderDifficulty(_ round: OverUnderRound) -> Double {
        let magnitude = max(abs(round.threshold), abs(round.actualValue))
        guard magnitude > 0.0001 else { return 1 }
        let relativeGap = abs(round.actualValue - round.threshold) / magnitude
        return 1 - min(1, relativeGap / overUnderObviousRelativeGap)
    }
}

/// Which blitz a rung is, and how long it runs.
///
/// Duration rises with the rung because it is a **variance dial**: measured over real boards, a
/// 60s run spans a 1.000 → 0.278 win rate while a 180s run spans 1.000 → 0.011. The short end is
/// not a gentler rung, it is a noisier one — at 60s a weak side finishes no board at all, since
/// keep4's par alone is 120 seconds. So the bottom of the ladder, where the target is 0.90 and
/// the floor never binds, can afford a minute; the middle needs three; and a boss gets five,
/// where the spread is tightest and the result is most nearly a statement about who knew more.
enum LadderBlitz {
    /// Rungs at or below this run for one minute — the band whose targets sit above 60s blitz's
    /// measured 0.278 floor, so the short format's own limit never becomes the rung's.
    static let oneMinuteMaxRung = 6

    static func duration(forRung rung: Int, isBoss: Bool) -> BlitzDuration {
        if isBoss { return .five }
        return rung <= oneMinuteMaxRung ? .one : .three
    }
}
