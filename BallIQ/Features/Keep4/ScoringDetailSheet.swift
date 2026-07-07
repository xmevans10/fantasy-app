import SwiftUI

/// The formula behind a Keep4/Cut4 puzzle's hidden ranking, resolved to a plain-English
/// point table. Rows are read from `ScoringRule.presets` — the client mirror of grade.py's
/// `_FANTASY` — never re-hardcoded, so the sheet can't drift from the math that actually
/// ranked the cards.
struct ScoringBreakdown: Equatable {
    struct Row: Identifiable, Equatable {
        let stat: String
        let label: String     // plain-English noun, e.g. "Receiving TD"
        let points: Double    // per-unit coefficient straight from the preset
        var id: String { stat }
    }

    struct FormulaSection: Identifiable, Equatable {
        let heading: String?  // role split when a sport ships two formulas (hitters/pitchers)
        let scaleKey: String
        let rows: [Row]
        let caption: String?  // per-scale fine print (per-game averages, stacking bases)
        var id: String { scaleKey }
    }

    let sections: [FormulaSection]
    /// True when the puzzle's exact scale is known (a baked `scale` key or a daily theme
    /// match); false for legacy community rows, which show the sport's default formulas.
    let exact: Bool

    /// Resolve a puzzle's formula: the baked scale key (community publishes carry one since
    /// the explainer shipped), else the daily theme whose title the puzzle carries, else the
    /// sport's shipped default formulas.
    init(puzzle: Keep4Puzzle, themes: [Keep4Theme] = Keep4Theme.bundled) {
        let known = puzzle.scale ?? themes.first(where: { $0.title == puzzle.theme })?.scale
        if let known, let section = Self.section(scale: known, sport: puzzle.sport, heading: nil) {
            sections = [section]
            exact = true
            return
        }
        sections = Self.sportDefaults(puzzle.sport).compactMap {
            Self.section(scale: $0.scale, sport: puzzle.sport, heading: $0.heading)
        }
        exact = false
    }

    // MARK: - Resolution

    /// One formula section for a grade-scale key, or nil for a non-points scale. Single-game
    /// scales reuse the season coefficients under a `_game` suffix (mirrors grade.py).
    static func section(scale: String, sport: Sport, heading: String?) -> FormulaSection? {
        let base = scale.hasSuffix("_game") ? String(scale.dropLast("_game".count)) : scale
        guard let rule = ScoringRule.preset(base), rule.isPoints else { return nil }
        let rows: [Row] = rule.terms.compactMap { term in
            switch term.norm {
            case .points(let per), .eraPoints(let per):
                return Row(stat: term.stat, label: label(term.stat, scale: base, sport: sport),
                           points: per)
            case .fixed, .eraAdjusted:
                return nil
            }
        }
        guard !rows.isEmpty else { return nil }
        return FormulaSection(heading: heading, scaleKey: base, rows: rows,
                              caption: caption(for: base))
    }

    /// What to show when the exact scale is unrecoverable (legacy community rows): the
    /// sport's shipped formulas, split by role where the sport grades two ways.
    private static func sportDefaults(_ sport: Sport) -> [(heading: String?, scale: String)] {
        switch sport {
        case .nfl:      return [(nil, "nfl_fantasy")]
        case .nba:      return [(nil, "nba_fantasy")]
        case .baseball: return [("Hitters", "baseball_hitter_fantasy"),
                                ("Pitchers", "baseball_pitcher_fantasy")]
        case .soccer:   return [("Attackers & midfielders", "soccer_attacker_fantasy"),
                                ("Defenders & keepers", "soccer_defender_fantasy")]
        case .tennis:   return [(nil, "tennis_fantasy")]
        }
    }

    // MARK: - Copy

    /// Plain-English row noun per stat key. Display copy only — the coefficient next to it
    /// always comes from the preset. Falls back to the `ScoringStat` card label, then the
    /// raw key, so an unmapped future stat degrades to terse rather than wrong.
    private static func label(_ stat: String, scale: String, sport: Sport) -> String {
        // Same raw key means "walks drawn" for hitters but "walks allowed" for pitchers.
        if stat == "base_on_balls" {
            return scale == "baseball_pitcher_fantasy" ? "Walk allowed" : "Walk"
        }
        let names: [String: String] = [
            "passing_yards": "Passing yards", "passing_tds": "Passing TD",
            "interceptions": "Interception thrown", "receptions": "Reception",
            "receiving_yards": "Receiving yards", "receiving_tds": "Receiving TD",
            "rushing_yards": "Rushing yards", "rushing_tds": "Rushing TD",
            "ppg": "Point", "rpg": "Rebound", "apg": "Assist", "spg": "Steal", "bpg": "Block",
            "hits": "Hit", "doubles": "Double", "triples": "Triple", "home_runs": "Home run",
            "runs": "Run scored", "rbi": "RBI", "stolen_bases": "Stolen base",
            "innings_pitched": "Inning pitched", "strike_outs": "Strikeout",
            "wins": "Win", "saves": "Save", "earned_runs": "Earned run",
            "goals": "Goal", "assists": "Assist", "appearances": "Appearance",
            "clean_sheets": "Clean sheet",
            "matches_won": "Match win", "matches_lost": "Match loss",
            "titles": "Title", "grand_slams": "Grand Slam",
        ]
        return names[stat] ?? ScoringStat.find(stat, sport: sport)?.label
            ?? stat.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func caption(for scale: String) -> String? {
        switch scale {
        case "nba_fantasy":
            return "Applied to the season's per-game averages."
        case "baseball_hitter_fantasy":
            return "Extra-base points stack on the hit itself — a home run nets +4 in total."
        default:
            return nil
        }
    }

    /// "+6", "−2", "+1.5", and the fantasy-idiomatic "+1 per 25" for fractional yardage
    /// rates (only when the per-1 form is the natural read — 0.5 stays "+0.5").
    static func pointsText(_ per: Double) -> String {
        if per > 0, per < 1 {
            let inv = 1 / per
            if inv >= 5, abs(inv - inv.rounded()) < 0.001 {
                return "+1 per \(Int(inv.rounded()))"
            }
        }
        let mag = abs(per)
        let num = mag == mag.rounded() ? "\(Int(mag))" : String(format: "%.1f", mag)
        return (per < 0 ? "−" : "+") + num
    }
}

/// "How it's scored" — the tap-through detail behind the pre-game `ScoringNoteChip`: the
/// actual point formula (or, for Vibes, an honest "there is no formula"), plus a provenance
/// footnote saying where the formula comes from. Deliberately spoiler-free: no player
/// totals, since it's shown before the puzzle is played.
struct ScoringDetailSheet: View {
    let puzzle: Keep4Puzzle
    var author: String? = nil
    /// True when opened from a community puzzle — gates the "author may have picked a
    /// variant" hedge, which would be wrong copy on a daily puzzle.
    var isCommunity: Bool = false

    private var kind: ScoringKind { puzzle.scoringKind() }
    private var breakdown: ScoringBreakdown { ScoringBreakdown(puzzle: puzzle) }

    /// Screenshot runs start expanded so the era card/footnote are capturable without a drag.
    @State private var detent: PresentationDetent =
        DebugLaunch.autoOpenScoringInfo ? .large : .medium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if kind == .vibes {
                    vibesPanel
                } else {
                    ForEach(breakdown.sections) { formulaCard($0) }
                    if kind == .era { eraCard }
                    footnote
                }
            }
            .padding(20)
            .padding(.top, 10)
            .padding(.bottom, 16)   // keep the footnote clear of the home indicator
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 44, height: 44)
                    .background(kind.tintBg)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("How it's scored")
                        .textCase(.uppercase)
                        .font(.label11)
                        .kerning(1)
                        .foregroundStyle(Color.textMuted)
                    Text(title)
                        .textCase(.uppercase)
                        .font(.title)
                        .foregroundStyle(Color.textPrimary)
                }
            }
            Text(intro)
                .font(.body14)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch kind {
        case .ppr:
            switch puzzle.sport {
            case .nfl:    return "Real PPR fantasy points"
            case .tennis: return "Season résumé points"
            default:      return "Real fantasy points"
            }
        case .era:   return "Era-adjusted fantasy points"
        case .vibes: return "Author's call"
        }
    }

    private var intro: String {
        switch kind {
        case .ppr:
            return puzzle.sport == .tennis
                ? "Every card is scored from its real season results using the table below. The four highest totals are the correct Keeps."
                : "Every card is worth the fantasy points its real stat line produced. Add up the table below — the four highest totals are the correct Keeps."
        case .era:
            return "Every card starts from its real fantasy points, then gets adjusted for its era — so a monster season from a low-scoring year isn't buried by modern stat inflation."
        case .vibes:
            let whose = author.map { "@\($0)" } ?? "The author"
            return "\(whose) put these eight in order by feel — no formula, no stat math. The numbers on the cards are evidence, not the answer key."
        }
    }

    // MARK: - Formula table

    private func formulaCard(_ section: ScoringBreakdown.FormulaSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading = section.heading {
                Text(heading)
                    .textCase(.uppercase)
                    .font(.label12)
                    .kerning(0.5)
                    .foregroundStyle(Color.textMuted)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 {
                        Rectangle().fill(Color.hairline).frame(height: Hairline.width)
                    }
                    HStack {
                        Text(row.label)
                            .font(.bodyStrong)
                            .foregroundStyle(Color.textPrimary)
                        Spacer(minLength: 12)
                        Text(ScoringBreakdown.pointsText(row.points))
                            .font(.statValue)
                            .foregroundStyle(row.points < 0 ? Color.dangerText : Color.accentText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
            .cardSurface()
            if let caption = section.caption {
                Text(caption)
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
            }
        }
    }

    // MARK: - Era / Vibes panels

    private var eraCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Then: the era index", systemImage: "clock.arrow.circlepath")
                .textCase(.uppercase)
                .font(.label12)
                .foregroundStyle(Color.proText)
            Text("The point total is multiplied by an era index: the position's all-time average total divided by the average from that season's year. Scarce eras multiply up, inflated eras trim down — and everyone from the same position and year gets the same multiplier, so it never reorders peers.")
                .font(.body14)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.proBg)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var vibesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No formula", systemImage: "quote.bubble.fill")
                .textCase(.uppercase)
                .font(.label12)
                .foregroundStyle(Color.warningText)
            Text("Vibes puzzles are pure opinion: great seasons, big names, personal bias — whatever moved the author. Your job is to read their mind, not the math, so no point table exists to study.")
                .font(.body14)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warningBg)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: - Provenance footnote

    /// Honest sourcing for the formula — real industry standard vs simplified vs BallIQ's
    /// own invention. One line per sheet, keyed off the first section's scale.
    private var footnote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .bold))
                .padding(.top, 2)
            Text(footnoteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.label12)
        .foregroundStyle(Color.textMuted)
    }

    private var footnoteText: String {
        var lines = [provenance(for: breakdown.sections.first?.scaleKey ?? "")]
        if kind == .era {
            lines.append("The era index is BallIQ's own, built from league-wide averages by position and year.")
        }
        if !breakdown.exact, isCommunity, puzzle.sport == .nfl {
            lines.append("This community puzzle predates formula tagging — its author may have picked the Half-PPR or Standard variant instead.")
        }
        return lines.joined(separator: " ")
    }

    private func provenance(for scale: String) -> String {
        switch scale {
        case "nfl_fantasy", "nfl_skill_ppr", "nfl_qb_fantasy":
            return "This is the industry-standard full-PPR formula — the same default scoring used on ESPN, Yahoo, and Sleeper."
        case "nfl_fantasy_half":
            return "Half-PPR: the industry-standard formula with receptions at half a point."
        case "nfl_fantasy_standard":
            return "Standard (non-PPR) scoring — receptions themselves score nothing."
        case "nba_fantasy":
            return "Modeled on DraftKings-style fantasy scoring, lightly simplified."
        case "baseball_hitter_fantasy", "baseball_pitcher_fantasy":
            return "Classic points-league baseball scoring convention."
        case "soccer_attacker_fantasy", "soccer_defender_fantasy":
            return "Inspired by Fantasy Premier League scoring, simplified to one shared rate per role."
        case "tennis_fantasy":
            return "BallIQ's own formula — there's no standard fantasy game for tennis, so seasons are scored as résumés: wins carry the total, Slams tower over everything."
        default:
            return "BallIQ's own scoring formula."
        }
    }
}
