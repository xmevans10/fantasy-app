import SwiftUI

/// Staggered entrance — one orchestrated reveal per screen (the frontend-aesthetics guidance's
/// "one well-orchestrated page load with staggered reveals beats scattered micro-interactions").
/// Apply with an increasing index down the screen. Honors Reduce Motion.
struct HeroReveal: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(Motion.overshoot.delay(Double(index) * 0.07)) { shown = true }
            }
    }
}

extension View {
    func heroReveal(_ index: Int) -> some View { modifier(HeroReveal(index: index)) }
}
