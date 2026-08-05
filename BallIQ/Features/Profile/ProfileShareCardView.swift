import SwiftUI

/// Shareable identity card (M13 share-card pattern, matching `DraftSpinShareCardView`: Prime
/// Time frame, ink border, hard ledge). Takes its data as plain params rather than reading
/// `container` directly so it stays a pure, previewable view — `ProfileView` supplies the
/// snapshot at share time.
struct ProfileShareCardView: View {
    let username: String
    let avatar: String
    let sport: Sport
    let tier: Tier
    let rating: Int
    let streak: Int
    let level: Int

    var body: some View {
        ShareCardFrame {
            // The tier's own color, not a flat accent — a legend card should look like a
            // different, louder object than a bronze one, the same way the tier badge does
            // everywhere else in the app.
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Wordmark(size: 20)
                    Spacer()
                    Text("MY PROFILE").font(.custom(FontName.condBlack, size: 14)).foregroundStyle(tier.onColor.opacity(0.85))
                }
                HStack(spacing: 10) {
                    AvatarView(avatar: avatar, size: 52, background: tier.onColor.opacity(0.14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(username)").font(.custom(FontName.condBlack, size: 22)).foregroundStyle(tier.onColor)
                        HStack(spacing: 4) {
                            Image(systemName: tier.symbol).font(.system(size: 11, weight: .bold))
                            Text("\(tier.name.uppercased()) · \(sport.displayName.uppercased())")
                                .font(.custom(FontName.condBold, size: 13))
                        }
                        .foregroundStyle(tier.onColor.opacity(0.9))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tier.color)
            .overlay(alignment: .topTrailing) {
                // Baked-in sheen so a screenshot still reads as "special," same treatment as
                // Keep4/Draft & Spin's rare-outcome header.
                LinearGradient(colors: [tier.onColor.opacity(0.3), tier.onColor.opacity(0)],
                               startPoint: .topTrailing, endPoint: .center)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                shareStat("RATING", "\(rating)")
                shareStat("STREAK", "\(streak)", icon: streak > 0 ? "flame.fill" : nil)
                shareStat("LEVEL", "\(level)")
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.surface1)

            ShareCardFooter()
        }
    }

    private func shareStat(_ label: String, _ value: String, icon: String? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.dangerText)
                }
                Text(value).font(.custom(FontName.condBlack, size: 20)).foregroundStyle(Color.textPrimary)
            }
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    func rendered(scale: CGFloat = 3) -> Image { renderedForShare(scale: scale) }
}
