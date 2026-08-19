import SwiftUI

/// The Journeyman board: a career as a vertical run of club crests, each with its year span.
///
/// **The whole path is shown at once.** An earlier build revealed it a club at a time and priced
/// each reveal; that made the game about when to spend a reveal, when the game is meant to be
/// "here is a career — who is this?". What it costs you now is a wrong guess, not a look.
///
/// One component, two callers: the game view and the result view render the identical timeline,
/// so "what a stint looks like" is defined once (AGENTS.md §4).
struct CareerPathTimeline: View {
    let sport: Sport
    let stints: [JourneymanPuzzle.Stint]
    /// Shown under the path when the career had more clubs than the board does.
    var truncated: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stints.enumerated()), id: \.element.id) { index, stint in
                if index > 0 { connector }
                row(stint)
            }
            if truncated { truncationNote }
        }
    }

    // MARK: - Rows

    private func row(_ stint: JourneymanPuzzle.Stint) -> some View {
        let palette = TeamColors.palette(sport: sport, abbr: stint.teamAbbr, league: stint.league)
        return HStack(spacing: 14) {
            // `showsLogo: false` for a historical stint: the code's modern crest belongs to a
            // different franchise now (ESPN's `nfl/hou` badge is the Texans), so hanging it
            // next to "Oilers 1996" would undo the pipeline's own naming fix. The badge falls
            // back to the abbreviation in the club's colors, which is honest.
            TeamLogoBadge(sport: sport, teamAbbr: stint.teamAbbr, tint: palette.primary,
                          league: stint.league, size: 46, showsLogo: !(stint.historical ?? false))
            VStack(alignment: .leading, spacing: 2) {
                Text(stint.teamName)
                    .font(.custom(FontName.condBlack, size: 18))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                Text(stint.yearsLabel)
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stint.teamName), \(stint.yearsLabel)")
    }

    /// The line between two cards, so the column reads as one career rather than a list of
    /// unrelated clubs.
    private var connector: some View {
        Rectangle()
            .fill(Color.accentFill)
            .frame(width: 2, height: 14)
            .padding(.leading, 36)
            .accessibilityHidden(true)
    }

    private var truncationNote: some View {
        Text("Earlier clubs not shown")
            .font(.label11)
            .foregroundStyle(Color.textMuted)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    let stints = [
        JourneymanPuzzle.Stint(order: 1, teamAbbr: "LAC", teamName: "Chargers", league: "",
                               firstYear: 2001, lastYear: 2005),
        JourneymanPuzzle.Stint(order: 2, teamAbbr: "NO", teamName: "Saints", league: "",
                               firstYear: 2006, lastYear: 2020),
    ]
    return ScrollView {
        CareerPathTimeline(sport: .nfl, stints: stints)
            .padding(16)
    }
    .background(Color.appBackground)
}
