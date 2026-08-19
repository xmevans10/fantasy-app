import SwiftUI

/// How obscure a puzzle's mystery subject is — the one tier vocabulary the app has, shared by
/// every format whose board hides a single player behind progressive reveals (Who Am I?,
/// Journeyman). The tier scales the points on offer and biases what the pipeline is willing to
/// serve on a given day.
///
/// This started life nested inside `WhoAmIPuzzle` and was lifted out when Journeyman needed the
/// identical three tiers, the identical multipliers, and the identical chip. `WhoAmIPuzzle
/// .Difficulty` remains a typealias for it (below), so every existing call site, every test, and
/// every persisted raw value ("easy"/"medium"/"hard") is untouched by the move.
/// Mirrors `tools/ingest/whoami_clues.py`'s `DIFFICULTIES`: the tier drives both how hard the
/// subject is *and* how revealing the board is (Who Am I? biases its clue draw per tier).
enum SubjectDifficulty: String, Codable, CaseIterable {
    case easy, medium, hard

    /// Score multiplier — the payoff for a deeper cut.
    ///
    /// Owned here rather than read from `content` on purpose: community puzzles decode
    /// through this same model, and a score multiplier is not something puzzle content
    /// gets to set for itself. `tools/ingest/whoami_clues.py`'s `POINT_MULTIPLIER` holds
    /// the same three numbers and `test_point_multipliers_match_the_swift_table` reads
    /// them back out of *this file*, so the two can't drift silently.
    var multiplier: Double {
        switch self {
        case .easy: return 1.0
        case .medium: return 1.25
        case .hard: return 1.6
        }
    }

    var badgeLabel: String {
        switch self {
        case .easy: return String(localized: "EASY")
        case .medium: return String(localized: "MEDIUM")
        case .hard: return String(localized: "HARD")
        }
    }

    var symbol: String {
        switch self {
        case .easy: return "circle"
        case .medium: return "circle.lefthalf.filled"
        case .hard: return "flame.fill"
        }
    }

    // MARK: - Palette. A green → orange → red ramp, so the tier reads before the word does.
    // Deliberately NOT volt (PuzzleGrain owns that hue) and not accent (the puzzle-TYPE
    // chip owns it, and the Who Am I card's type chip is volt on a sport-colored band) —
    // a difficulty chip sitting in the same header row has to be its own signal.
    // Solid-filled rather than the header's default translucent tint for the same reason:
    // three chips that differ only in wording aren't a difficulty indicator.

    var tint: Color {
        switch self {
        case .easy: return .successFill
        case .medium: return .warningFill
        case .hard: return .dangerFill
        }
    }

    var onTint: Color {
        switch self {
        case .easy: return .onSuccess
        case .medium: return .onWarning
        case .hard: return .onDanger
        }
    }

    var tintBg: Color {
        switch self {
        case .easy: return .successBg
        case .medium: return .warningBg
        case .hard: return .dangerBg
        }
    }

    var tintText: Color {
        switch self {
        case .easy: return .successText
        case .medium: return .warningText
        case .hard: return .dangerText
        }
    }

    /// Spelled-out payoff for the tier, for the pre-game header ("1.6x points").
    ///
    /// `.formatted()` rather than `String(format:)`: `%.2g` renders 1.25 as "1.2" — the chip
    /// under-reported the medium multiplier on screen (caught in the simulator) — and a
    /// C-format specifier also can't localize the decimal separator, so a Spanish user would
    /// have seen "1.25x" where the rest of the app says "1,25". This drops trailing zeros
    /// (1.0 → "1") and keeps the locale's separator.
    var multiplierLabel: String {
        String(localized: "\(multiplier.formatted())x points")
    }

    /// Unknown tier strings decode as `.medium` rather than throwing. A thrown error here
    /// would fail the decode for the *whole* whoami fetch (rows are decoded as one array),
    /// dropping every user to the bundled pool over one unrecognized word — the same trap
    /// `ClueKind` documents. A future fourth tier must not be able to do that.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SubjectDifficulty(rawValue: raw) ?? .medium
    }
}

extension WhoAmIPuzzle {
    /// The name this type was born under. Kept as a typealias rather than rewritten across the
    /// app: the raw values are a wire contract with `puzzles.content`, and the old spelling
    /// reads correctly at Who Am I?'s own call sites.
    typealias Difficulty = SubjectDifficulty
}
