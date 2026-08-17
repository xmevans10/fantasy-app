import Foundation

/// A format whose board is a **stable row in `puzzles`** — the shared domain of
/// `puzzles.format`, `versus_challenges.format` and `ladder_rungs.mode`, and the same set
/// `ChallengeLink` can address.
///
/// Over/Under and Draft & Spin are deliberately absent, and for the same reason in every one of
/// those places: their rounds are drawn with a seeded RNG *over a sampled player pool*
/// (`PlayerSeasonCatalog.draftSpinSample`), so there is no single row that identifies "the board
/// both of you played". A duel, a challenge link, or a ladder rung that silently compared two
/// different boards would be worse than not offering one.
///
/// This exists as one shared type rather than three parallel enums (AGENTS.md §4): before it,
/// `ChallengeLink.Format` was its own `{grid, keep4}` and the Versus tables had no format column
/// at all, so adding a second duelable format meant inventing a third spelling of the same three
/// strings. The raw values are the wire contract with the server — do not rename them.
enum PuzzleFormat: String, Codable, CaseIterable, Equatable, Hashable {
    case keep4, whoami, grid

    /// Player-facing name. Matches the format tiles on Home (`GameFormat.all`), which is where
    /// most players learn these names.
    var displayName: String {
        switch self {
        case .keep4:  return String(localized: "K4C4")
        case .whoami: return String(localized: "Who am I?")
        case .grid:   return String(localized: "The Grid")
        }
    }

    /// The name to use **inside a sentence**, which is not always `displayName`.
    ///
    /// "The Grid" is a title — correct on a tile, wrong the moment anything needs to put a
    /// determiner in front of it ("today's NFL The Grid"). The share headline is the app's
    /// single highest-leverage sentence, so it gets the mid-sentence form and the tiles keep
    /// the title form; the alternative was rewriting the sentence around the title, which
    /// produced "on NFL's The Grid today".
    var shareName: String {
        switch self {
        case .keep4:  return String(localized: "K4C4")
        case .whoami: return String(localized: "Who Am I?")
        case .grid:   return String(localized: "Grid")
        }
    }

    /// SF Symbol, matching the format's Home tile.
    var symbol: String {
        switch self {
        case .keep4:  return "rectangle.stack.fill"
        case .whoami: return "questionmark.circle.fill"
        case .grid:   return "square.grid.3x3.fill"
        }
    }

    /// The rating-engine weight class this format plays at. Keep4 maps to `.keep4Normal`
    /// because a duel is never hard mode — the opponent has to be on the same board *and* the
    /// same ruleset for the comparison to mean anything.
    var kind: GameFormatKind {
        switch self {
        case .keep4:  return .keep4Normal
        case .whoami: return .whoAmI
        case .grid:   return .grid
        }
    }

    /// How many decisions a run of this format contains — the denominator every `performance`
    /// is built from, and what a duel scoreboard renders as "6/8".
    var decisionCount: Int {
        switch self {
        case .keep4:  return 8
        case .whoami: return 1
        case .grid:   return 9
        }
    }

    /// Default duel clock, in seconds. Grid gets the most because nine free-text answers is
    /// simply more typing than eight swipes; Who Am I? gets the least because its own scoring
    /// curve already punishes dithering.
    var defaultDuelSeconds: Int {
        switch self {
        case .keep4:  return 120
        case .whoami: return 90
        case .grid:   return 180
        }
    }

    /// Unknown formats decode as `.keep4` rather than throwing. A thrown error here would fail
    /// the decode for a whole array of challenges (they are decoded as one batch), emptying the
    /// Versus tab over one unrecognized word — the same trap `ClueKind` documents. A future
    /// fourth format must not be able to do that to a shipped build.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PuzzleFormat(rawValue: raw) ?? .keep4
    }
}
