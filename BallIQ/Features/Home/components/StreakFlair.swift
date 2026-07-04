import SwiftUI

/// Compact streak indicator for the Home toolbar (flame + day count) — the full
/// `StreakBar` card is too large for a nav bar slot.
struct StreakFlair: View {
    let streak: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(streak > 0 ? Color.warningFill : Color.textMuted)
            Text("\(streak)")
                .font(.label12)
                .foregroundStyle(Color.textPrimary)
        }
    }
}
