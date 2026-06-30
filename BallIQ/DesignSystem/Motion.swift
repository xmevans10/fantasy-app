import SwiftUI

/// Motion tokens (CDS `--dur-*` / `--ease-*`). Every animation in the app references these —
/// no ad-hoc `.spring(response:)` scattered around.
enum Motion {
    static let durFast: Double = 0.15
    static let durSnap: Double = 0.25
    static let durBase: Double = 0.35
    static let durSlow: Double = 0.55

    /// Standard ease-out for fades and simple transitions.
    static var easeOut: Animation { .easeOut(duration: durBase) }
    /// Crisp settle for control state changes and zone snaps.
    static var snap: Animation { .spring(response: durSnap, dampingFraction: 0.82) }
    /// Playful settle with a little overshoot — drag releases, reveals.
    static var overshoot: Animation { .spring(response: durBase, dampingFraction: 0.62) }
}

/// A number that counts up to `value` on appear/change. Honors Reduce Motion.
struct CountUpText: View {
    let value: Int
    var prefix: String = ""
    var font: Font = .scoreReveal
    var color: Color = .accentText
    var duration: Double = Motion.durSlow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    var body: some View {
        Text("\(prefix)\(shown)")
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText())
            .onAppear { run() }
            .onChange(of: value) { _, _ in run() }
    }

    private func run() {
        guard value != 0 else { shown = 0; return }
        if reduceMotion { shown = value; return }
        shown = 0
        let steps = 24
        let stepValue = max(value / steps, 1)
        var current = 0
        Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { timer in
            current = min(current + stepValue, value)
            withAnimation(.easeOut(duration: 0.05)) { shown = current }
            if current >= value { timer.invalidate() }
        }
    }
}
