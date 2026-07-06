import SwiftUI

/// How a Keep4/Cut4 puzzle's hidden grades were produced — the grading philosophy, surfaced as
/// a badge on puzzle cards and a pre-game explainer so players know what they're ranking by.
///
/// - `.ppr` — objective fantasy-point totals (NFL PPR / NBA fantasy); the grade IS the season's
///   real point total. Every daily pipeline theme except the era theme grades this way, as do
///   community puzzles built from the shipped fantasy presets.
/// - `.era` — still objective math, but the raw total is rescaled by the per-(position, year)
///   era volume index (see `ScoringRule.eraTotalIndex`), so scarcer eras count for more.
/// - `.vibes` — no formula at all. The author drag-orders the 8 picks by feel; the grade is just
///   a rank placeholder (descending by position in that order) so `Keep4Puzzle.correctKeepIDs`
///   can reuse the same top-4/bottom-4 math — but the number itself is never shown to players.
enum ScoringKind: String, Codable {
    case ppr
    case era
    /// Raw value stays "custom" for backward compatibility with already-published rows.
    case vibes = "custom"

    /// Classify the rule a puzzle was graded with. Points math is objective (`.ppr`/`.era`).
    /// There's no rule-based path to `.vibes` — vibes puzzles have no `ScoringRule` at all and
    /// set this case directly at publish.
    init(rule: ScoringRule) {
        let hasEra = rule.terms.contains {
            if case .eraPoints = $0.norm { return true } else { return false }
        }
        self = hasEra ? .era : .ppr
    }

    // MARK: - Display

    /// SF Symbol shown alongside the badge label and in the pre-game explainer.
    var symbol: String {
        switch self {
        case .ppr:    return "bolt.fill"
        case .era:    return "clock.arrow.circlepath"
        case .vibes:  return "quote.bubble.fill"
        }
    }

    /// Short ALL-CAPS badge text for puzzle cards. PPR is an NFL term; other sports use the
    /// generic fantasy label — kept to one word so the card header's format name doesn't
    /// truncate next to the grain + sport chips (the explainer chip carries the full copy).
    func badgeLabel(for sport: Sport) -> String {
        switch self {
        case .ppr:    return sport == .nfl ? "PPR" : "FANTASY"
        case .era:    return "ERA-ADJUSTED"
        case .vibes:  return "VIBES"
        }
    }

    /// 1–2 line scoring-method explainer shown above the first card in the play flow.
    /// `author` (community username) personalizes the vibes copy when available.
    func explainer(sport: Sport, author: String? = nil) -> String {
        switch self {
        case .ppr:
            return sport == .nfl ? "Ranked by real PPR fantasy points"
                                 : "Ranked by real fantasy points"
        case .era:
            return "Ranked by era-adjusted fantasy points — scarcer eras count for more"
        case .vibes:
            let whose = author.map { "@\($0)'s" } ?? "the author's"
            return "Vibes — \(whose) gut call on what makes a great season, no formula"
        }
    }

    /// Unit under the revealed grade number. Only shown for points kinds — vibes puzzles never
    /// display a number at all (see `Keep4CardView.showGrade`), so this is unused there.
    var gradeUnit: String { "PTS" }

    // MARK: - Palette (Prime Time roles: cool/objective vs warm/human)

    /// Chip text color on an app surface (readable `*Text` role).
    var tint: Color {
        switch self {
        case .ppr:    return .accentText
        case .era:    return .proText
        case .vibes:  return .warningText
        }
    }

    /// Chip background on an app surface (soft `*Bg` role).
    var tintBg: Color {
        switch self {
        case .ppr:    return .accentBg
        case .era:    return .proBg
        case .vibes:  return .warningBg
        }
    }
}

/// The scoring-method explainer chip — how a puzzle's hidden ranking was produced, tinted with
/// the kind's role color so vibes-based puzzles read warm vs the cool objective ones. Rounded
/// rect, not a capsule: the era/custom copy wraps to two lines on small screens.
struct ScoringNoteChip: View {
    let kind: ScoringKind
    let sport: Sport
    var author: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: kind.symbol).font(.system(size: 11, weight: .bold))
            Text(kind.explainer(sport: sport, author: author))
                .font(.label11)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(kind.tintBg)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension Keep4Puzzle {
    /// Effective scoring kind. A baked `scoring` value (written at community publish) wins;
    /// otherwise daily puzzles resolve era-adjustment by matching the theme title against the
    /// bundled theme export. Everything else — all remaining daily themes and legacy community
    /// rows (created before `scoring` existed, when only fantasy presets were creatable) — is
    /// objective fantasy points.
    func scoringKind(themes: [Keep4Theme] = Keep4Theme.bundled) -> ScoringKind {
        if let scoring { return scoring }
        if themes.contains(where: { $0.title == theme && $0.eraAdjusted }) { return .era }
        return .ppr
    }
}
