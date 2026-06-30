import SwiftUI

/// A "today's daily game" card — a broadcast "matchup" block with a colored header band.
struct DailyGameCard: View {
    let formatName: String
    let symbol: String
    let sport: Sport
    let title: String
    let subtitle: String
    let completed: Bool
    var accent: Color = .accentFill
    var onAccent: Color = .onAccent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Colored header band
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                    Text(formatName.uppercased())
                        .font(.heading)
                    Spacer()
                    Text(sport.displayName)
                        .font(.label11)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(onAccent.opacity(0.18))
                        .clipShape(Capsule())
                }
                .foregroundStyle(onAccent)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent)

                // Body
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle.uppercased())
                            .font(.label11)
                            .foregroundStyle(Color.textMuted)
                    }
                    Spacer(minLength: 8)
                    if completed {
                        Label("DONE", systemImage: "checkmark.circle.fill")
                            .font(.label12)
                            .foregroundStyle(Color.successText)
                    } else {
                        Text("PLAY")
                            .font(.heading)
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Color.accentFill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color.surface1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.borderInk, lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 0, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}
