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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Wordmark(size: 20)
                    Spacer()
                    Text("MY PROFILE").font(.custom(FontName.condBlack, size: 14)).foregroundStyle(Color.onAccent.opacity(0.85))
                }
                HStack(spacing: 10) {
                    Text(avatar)
                        .font(.system(size: 34))
                        .frame(width: 52, height: 52)
                        .background(Color.onAccent.opacity(0.14))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(username)").font(.custom(FontName.condBlack, size: 22)).foregroundStyle(Color.onAccent)
                        Text("\(tier.name.uppercased()) · \(sport.displayName.uppercased())")
                            .font(.custom(FontName.condBold, size: 13)).foregroundStyle(Color.onAccent.opacity(0.85))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentFill)

            HStack(spacing: 0) {
                shareStat("RATING", "\(rating)")
                shareStat("STREAK", "\(streak)")
                shareStat("LEVEL", "\(level)")
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.surface1)

            Text("PLAY AT PLAYBOOK")
                .font(.custom(FontName.condBold, size: 11))
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceMuted)
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2.5))
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color.borderInk).offset(x: 4, y: 4).padding(6))
    }

    private func shareStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.custom(FontName.condBlack, size: 20)).foregroundStyle(Color.textPrimary)
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    func rendered(scale: CGFloat = 3) -> Image {
        let renderer = ImageRenderer(content: self)
        renderer.scale = scale
        if let ui = renderer.uiImage { return Image(uiImage: ui) }
        return Image(systemName: "square.dashed")
    }
}
