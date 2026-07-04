import SwiftUI

/// What window of a player's production a Keep4/Cut4 puzzle's cards represent — surfaced as
/// a badge (mirrors `ScoringKind`/`ScoringNoteChip`) so players know what they're comparing
/// before they sort: one season, one single game, or an entire career.
///
/// Baked into the puzzle at assembly time (`assemble.py`'s `"grain": theme.grain`) or at
/// community publish (always `.season` today — the Create flow only offers season-grain
/// themes; single-game and career pools aren't wired into player search yet).
enum PuzzleGrain: String, Codable {
    case season
    case singleGame = "game"
    case career

    /// SF Symbol shown alongside the badge label and in the pre-game explainer.
    var symbol: String {
        switch self {
        case .season:     return "calendar"
        case .singleGame: return "sportscourt.fill"
        case .career:     return "trophy.fill"
        }
    }

    /// Short ALL-CAPS badge text for puzzle cards.
    var badgeLabel: String {
        switch self {
        case .season:     return "SEASON"
        case .singleGame: return "SINGLE GAME"
        case .career:     return "CAREER"
        }
    }

    /// Plural noun for "N ___" card-count subtitles (e.g. "8 seasons" / "8 games" / "8 careers").
    var countNoun: String {
        switch self {
        case .season:     return "seasons"
        case .singleGame: return "games"
        case .career:     return "careers"
        }
    }

    /// 1-line explainer shown above the first card in the play flow.
    var explainer: String {
        switch self {
        case .season:     return "Ranked by real single-season stats"
        case .singleGame: return "Ranked by one single-game performance, not a full season"
        case .career:     return "Ranked by real career totals across every season"
        }
    }

    // MARK: - Palette (one consistent hue, distinct from ScoringKind's accent/pro/warning
    // roles, so the two chip systems read as separate at a glance when both are shown).

    var tint: Color { .voltText }
    var tintBg: Color { .voltBg }
}

/// The grain-method explainer chip — mirrors `ScoringNoteChip`'s shape/role exactly.
struct GrainChip: View {
    let grain: PuzzleGrain

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: grain.symbol).font(.system(size: 11, weight: .bold))
            Text(grain.explainer)
                .font(.label11)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(grain.tint)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(grain.tintBg)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension Keep4Puzzle {
    /// Effective grain. A baked `grain` value wins; otherwise daily puzzles resolve it by
    /// matching the theme title against the bundled theme export. Community puzzles and any
    /// legacy row without a baked value default to `.season` (the only grain the Create flow
    /// has ever offered).
    func puzzleGrain(themes: [Keep4Theme] = Keep4Theme.bundled) -> PuzzleGrain {
        if let grain, let kind = PuzzleGrain(rawValue: grain) { return kind }
        if let matched = themes.first(where: { $0.title == theme }),
           let kind = PuzzleGrain(rawValue: matched.grain) {
            return kind
        }
        return .season
    }
}
