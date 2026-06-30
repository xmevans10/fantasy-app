import SwiftUI

struct StreakBar: View {
    let streak: Int
    let playedToday: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(streak > 0 ? Color.warningFill : Color.textMuted)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(streak)")
                    .font(.hero(38))
                    .foregroundStyle(Color.textPrimary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("DAY")
                    Text("STREAK")
                }
                .font(.heading)
                .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            Text(playedToday ? "TODAY ✓" : "PLAY TODAY")
                .font(.label12)
                .foregroundStyle(playedToday ? Color.onSuccess : Color.onVolt)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(playedToday ? Color.successFill : Color.voltFill)
                .clipShape(Capsule())
        }
        .padding(16)
        .cardSurface()
    }
}
