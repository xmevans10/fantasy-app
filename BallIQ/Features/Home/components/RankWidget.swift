import SwiftUI

struct RankWidget: View {
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
                    .foregroundStyle(tier.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tier.name.uppercased())
                        .font(.title)
                        .foregroundStyle(Color.textPrimary)
                    Text("NFL RATING")
                        .font(.label11)
                        .foregroundStyle(Color.textMuted)
                }
                Spacer()
                Text("\(rating)")
                    .font(.hero(40))
                    .foregroundStyle(tier.color)
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.surfaceMuted)
                        Capsule().fill(tier.color)
                            .frame(width: max(8, geo.size.width * progress))
                    }
                }
                .frame(height: 12)
                if let pts = pointsToNext {
                    Text("\(pts) PTS TO NEXT TIER")
                        .font(.label11)
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
        .padding(18)
        .cardSurface()
    }
}
