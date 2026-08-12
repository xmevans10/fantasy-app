import SwiftUI

/// Branded cold-launch splash: the app-icon monogram on hero blue, so the first frame after
/// tapping the icon is the same mark the user just tapped. Hands off to `onFinished`.
struct SplashView: View {
    var onFinished: () -> Void

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                Text("P")
                    .font(.custom(FontName.anton, fixedSize: 200))
                    .foregroundStyle(Color.voltFill)
                // Saira ships no italic face, and `.italic()` is a no-op on a custom font with
                // no synthesised oblique — so slant it geometrically. `c` shears the top of the
                // glyphs rightward; the offset re-centres what the shear pushed sideways.
                Text("prove you know ball")
                    .font(.custom(FontName.bodyMedium, fixedSize: 15))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.21, d: 1, tx: 0, ty: 0))
                    .offset(x: -2, y: -30)
            }
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentFill)
        .overlay(SpeedLines(color: .white, opacity: 0.05))
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
