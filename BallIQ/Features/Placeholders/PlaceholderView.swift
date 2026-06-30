import SwiftUI

/// Generic "Coming soon" stub so the full 5-tab IA from the brief is present.
struct PlaceholderView: View {
    let title: String
    let symbol: String
    let blurb: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.accentText)
                Text(title)
                    .font(.heading)
                    .foregroundStyle(Color.textPrimary)
                Text(blurb)
                    .font(.body14)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Text("Coming soon")
                    .font(.label12)
                    .foregroundStyle(Color.accentText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentBg)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
