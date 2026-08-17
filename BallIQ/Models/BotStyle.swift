import Foundation

/// How a bot plays — as distinct from how *well* it plays.
///
/// `bot_skill` answers "can this opponent beat me". Style answers "what is it like to play them",
/// which is the thing that makes an opponent a character rather than a difficulty setting. Two
/// bots at identical skill produce visibly different runs: one nails the gimmes and coin-flips
/// everything close, another is deadly on the obscure calls and overthinks the obvious.
///
/// **Every case is a transform on the two inputs `hitProbability` already takes**, plus where in
/// the run the decision falls. That keeps styles cheap, seeded and — crucially — modellable, so
/// `tools/ingest/ladder.py` can re-solve each rung's `bot_skill` against its bot's actual style
/// and the ladder's win-rate curve survives. `BallIQTests/LadderCurveTests` re-measures with this
/// solver and fails if the Python model drifts from these formulas.
///
/// Each style also carries a one-line description the player is shown *before* they play
/// (`styleLine` in the `bots` table). A style the player can't anticipate isn't a personality,
/// it's just noise.
enum BotStyle: String, Codable, CaseIterable {
    /// Fast and streaky. Difficulty hits harder than it should — obvious calls stay easy, close
    /// ones collapse toward a guess.
    case overeager
    /// Deliberate. Sharpens the middle of the difficulty range: strong when the metric gap is
    /// clear, weak the moment it tightens.
    case methodical
    /// Metronomic. The baseline — no transform, and reduced run-to-run variance, so they land
    /// near their expectation every time.
    case consistent
    /// Backwards. Better on the obscure calls than the obvious ones. The one style that inverts
    /// the difficulty signal, and the reason `difficulty` is a transformable input at all.
    case deepCuts
    /// Starts cold, finishes strong — skill ramps across the run.
    case slowBurn
    /// Very nearly perfect, with a small fixed chance of an inexplicable miss on anything.
    case prescient

    /// Chance of a decision going wrong regardless of skill or difficulty. Only `prescient`
    /// uses it: an opponent who is otherwise flawless needs a crack for the run to have any
    /// texture, and "stared into space and missed an easy one" is more characterful than
    /// shaving the skill number down.
    /// Deliberately small. A handicap this style carries is also a **ceiling on how hard the
    /// rung can be made**: at the top of the ladder the solver has already pushed `bot_skill`
    /// to 1.0, so anything the style subtracts there cannot be compensated for. At 0.06 the
    /// Oracle could not be tuned below a 0.47 player win rate on Keep4 and rung 27 came back
    /// *easier* than rung 24 — the curve inverted. 0.03 keeps the blink visible over a run
    /// without capping the last third of the ladder.
    var blinkChance: Double { self == .prescient ? 0.03 : 0 }

    /// How much of the clock this style spends, before the skill-based pacing in `BotSolver`.
    /// A rookie rushing and an archivist deliberating are half of what those two *feel* like.
    var paceMultiplier: Double {
        switch self {
        case .overeager:  return 0.72
        case .methodical: return 1.18
        case .consistent: return 1.0
        case .deepCuts:   return 1.06
        case .slowBurn:   return 1.15
        case .prescient:  return 0.85
        }
    }

    /// Reshapes the difficulty of one decision. Identity for `consistent`, which is what makes
    /// it the baseline every other style is legible against.
    ///
    /// `progress` is how far into the run this decision falls, 0...1 — only `slowBurn` reads it,
    /// but it has to be in the signature for the transform to stay a pure function of the
    /// inputs, which is what lets the Python model mirror it exactly.
    func difficulty(_ d: Double, progress: Double) -> Double {
        let clamped = min(max(d, 0), 1)
        switch self {
        case .consistent, .slowBurn, .prescient:
            return clamped
        case .overeager:
            // Everything hard gets harder; the gimmes are untouched because they were already
            // near-certain. Produces the streaky, all-or-nothing feel.
            return min(1, clamped * 1.35)
        case .methodical:
            // `d^1.4` pushes the middle of the range down — the "clear enough to reason about"
            // band becomes reliable — while leaving the genuinely close calls near 1.
            return pow(clamped, 1.4)
        case .deepCuts:
            // Mostly inverted, not fully: a scout who could not identify a superstar would read
            // as broken rather than specialised. 0.62 keeps the inversion legible while leaving
            // them competent on the obvious ones.
            return clamped * 0.38 + (1 - clamped) * 0.62
        }
    }

    /// Reshapes skill for one decision. Only `slowBurn` moves it.
    func skill(_ s: Double, progress: Double) -> Double {
        guard self == .slowBurn else { return s }
        // 0.72x at the first decision, 1.12x by the last, clamped. Losing to the Archivist
        // should feel like being worn down rather than outclassed from the start.
        // Same constraint as `blinkChance`: the early penalty is a texture, not a difficulty
        // cap. At 0.72 the Archivist's own rungs could not be tuned down to target.
        return min(1, s * (0.82 + 0.26 * min(max(progress, 0), 1)))
    }

    /// Unknown styles decode as `.consistent` rather than throwing — a style added server-side
    /// must not empty the roster on a shipped build (the rule `ClueKind` documents).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BotStyle(rawValue: raw) ?? .consistent
    }
}

/// What a bot says, keyed by the moment it says it. Mirrors `bots.voice`.
///
/// Deliberately a fixed, authored set rather than anything generated: these fire mid-run, when
/// the player has a clock ticking, so they have to be short, predictable and in character every
/// single time. Every field is optional — a bot with no line for a moment simply stays quiet,
/// which is better than a filler line.
struct BotVoice: Codable, Equatable {
    var intro: String?
    /// The bot has just pulled ahead of the player.
    var ahead: String?
    /// The player has just pulled ahead of the bot.
    var behind: String?
    var win: String?
    var lose: String?
    /// The player finished with a perfect run — worth its own reaction, because it is the one
    /// outcome where a losing opponent should sound impressed rather than sour.
    var playerPerfect: String?

    static let empty = BotVoice()

    /// The line for the end of a duel, from the **bot's** point of view.
    func closing(botWon: Bool, playerPerfect: Bool) -> String? {
        if playerPerfect, let line = self.playerPerfect { return line }
        return botWon ? win : lose
    }
}

/// A bot's colourway. A key mapped onto the app's own design tokens rather than a stored hex, so
/// the roster stays inside the design system and keeps working in both themes.
enum BotPalette: String, Codable, CaseIterable {
    case amber, teal, electric, green, plum, gold

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BotPalette(rawValue: raw) ?? .electric
    }
}
