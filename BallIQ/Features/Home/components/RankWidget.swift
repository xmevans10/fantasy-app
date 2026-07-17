import SwiftUI

struct RankWidget: View {
    /// The sport whose rating is displayed — the label must match the number.
    let sport: Sport
    let rating: Int

    private var tier: Tier { Tier.forRating(rating) }

    private var progress: Double {
        guard let floor = tier.nextTierFloor else { return 1 }
        let lower = tier.range.lowerBound
        let span = Double(floor - lower)
        return min(max(Double(rating - lower) / span, 0), 1)
    }

    private var pointsToNext: Int? {
        tier.nextTierFloor.map { $0 - rating }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: tier.symbol)
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(tier.onColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tier.name.uppercased())
                        .font(.title)
                        .foregroundStyle(tier.onColor)
                    Text("\(sport.displayName.uppercased()) RATING")
                        .font(.label11)
                        .foregroundStyle(tier.onColor.opacity(0.75))
                }
                Spacer()
                Text("\(rating)")
                    .font(.hero(44))
                    .foregroundStyle(tier.onColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tier.onColor.opacity(0.25))
                        Capsule().fill(tier.onColor)
                            .frame(width: max(8, geo.size.width * progress))
                    }
                }
                .frame(height: 12)
                if let pts = pointsToNext {
                    Text("\(pts) PTS TO NEXT TIER")
                        .font(.label11)
                        .foregroundStyle(tier.onColor.opacity(0.75))
                }
            }
        }
        .padding(18)
        // Broadcast hero, not a settings row (2026-07-17 "too much white" pass): the whole
        // block wears the tier's metal with speed lines behind the numerals. The Balatro
        // foil shimmer is reserved for Legend — over the lower tiers' fills it swallowed
        // the tier color entirely (screenshot-caught), and foil is meant for the one rare
        // card anyway. The `.hero(44)` numeral is Anton — the scoreboard face.
        .background(
            SpeedLines(color: tier.onColor, opacity: 0.08)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        )
        .blockCard(fill: tier.color)
        .foil(active: tier == .legend, cornerRadius: Radius.card)
    }
}
