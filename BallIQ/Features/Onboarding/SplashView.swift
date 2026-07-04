import SwiftUI

/// Branded cold-launch splash. Shows the wordmark, then hands off to `onFinished`.
struct SplashView: View {
    var onFinished: () -> Void

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HeroGlow(color: .accentFill)
                .frame(width: 360, height: 360)
                .opacity(shown ? 1 : 0)

            VStack(spacing: 12) {
                Wordmark(size: 72)
                Text("PROVE YOU KNOW BALL.")
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
            }
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .overlay(SpeedLines(color: .ink, opacity: 0.04))
        .onAppear {
            if reduceMotion {
                shown = true
                onFinished()
                return
            }
            withAnimation(Motion.overshoot) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                onFinished()
            }
        }
    }
}

#Preview {
    SplashView(onFinished: {})
}
