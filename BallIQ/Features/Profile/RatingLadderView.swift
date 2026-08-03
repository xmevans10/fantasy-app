import SwiftUI

/// The full per-sport rating ladder — demoted off Profile's front page (career stats lead there
/// now), but Leagues, Versus, and the season-badge ladder all still key off `RatingEngine`
/// underneath, so the detail still needs a home. Body is `ProfileView`'s old `ratingsCard`/
/// `ratingRow`/`tierProgress`, moved here verbatim.
struct RatingLadderView: View {
    @EnvironmentObject private var container: RepositoryContainer

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ratingsCard
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle("Ratings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var ratingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RATINGS").font(.label12).foregroundStyle(Color.textMuted)
            ForEach(Sport.allCases) { ratingRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private func ratingRow(_ sport: Sport) -> some View {
        let rating = container.rating(for: sport)
        let tier = Tier.forRating(rating)
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: sport.symbol).font(.system(size: 14)).foregroundStyle(tier.color)
                Text(sport.displayName).font(.heading).foregroundStyle(Color.textPrimary)
                Spacer()
                Text(tier.name.uppercased()).font(.label11).foregroundStyle(tier.color)
                Text("\(rating)").font(.hero(22)).foregroundStyle(Color.textPrimary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceMuted)
                    Capsule().fill(tier.color)
                        .frame(width: geo.size.width * tierProgress(rating: rating, tier: tier))
                }
            }
            .frame(height: 6)
            if let floor = tier.nextTierFloor {
                Text("\(floor - rating) to \(Tier.forRating(floor).name)")
                    .font(.label11).foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("Max tier").font(.label11).foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Fraction (0–1) of the way through the current tier's rating band.
    private func tierProgress(rating: Int, tier: Tier) -> CGFloat {
        let lo = tier.range.lowerBound, hi = tier.range.upperBound
        guard hi > lo else { return 1 }
        return CGFloat(min(max(rating - lo, 0), hi - lo)) / CGFloat(hi - lo)
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return NavigationStack { RatingLadderView() }.environmentObject(container)
}
