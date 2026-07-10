import SwiftUI

/// Every stat that matters for a player's real position, as a compact value-over-label
/// grid — THE shared way any game surface shows a player's full line (Draft & Spin's
/// board + results, and any future format's reveal). Same principle as the M18-era
/// card-metadata parity work (`PlayerMediaBadges`): one implementation, so a player's
/// stat treatment can't drift between formats. Position scoping goes through
/// `Sport.sliceForPosition`, the same mechanism that keeps a WR card from ever reading
/// "PASS YDS 0" (AGENTS.md §4) — this grid can never show another position's stat family.
struct PositionStatGrid: View {
    let sport: Sport
    let position: String
    let stats: [String: Double]
    /// Grid columns per row; 4 fits the standard card width at label11 sizes.
    var columns: Int = 4
    var valueSize: CGFloat = 14

    private var relevantStats: [ScoringStat] {
        sport.sliceForPosition(ScoringStat.catalog(for: sport), position: position,
                               minimum: 0, statKey: \.key)
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                  spacing: 8) {
            ForEach(relevantStats) { stat in
                if let value = stats[stat.key] {
                    VStack(spacing: 0) {
                        Text(stat.format(value))
                            .font(.custom(FontName.condBlack, size: valueSize))
                            .foregroundStyle(Color.textPrimary)
                        Text(stat.label.uppercased())
                            .font(.label11)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }
}
