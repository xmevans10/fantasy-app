import SwiftUI

// ConfettiSwiftUI is vendored as in-project source (BallIQ/ThirdParty), so it's the same module —
// no import needed.

/// Brand confetti palette.
enum Celebration {
    static let colors: [Color] = [.accentFill, .voltFill, .successFill, .warningFill, .dangerFill]
}

/// Fire a confetti burst when `trigger` changes. Honors Reduce Motion (no particles).
struct Celebrate: ViewModifier {
    @Binding var trigger: Int
    var intensity: Int = 60
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.confettiCannon(
            trigger: $trigger,
            num: reduceMotion ? 0 : intensity,
            confettis: [.shape(.circle), .shape(.triangle), .shape(.slimRectangle), .shape(.roundedCross)],
            colors: Celebration.colors,
            confettiSize: 12,
            rainHeight: 700,
            radius: 360,
            hapticFeedback: true
        )
    }
}

extension View {
    func celebrate(on trigger: Binding<Int>, intensity: Int = 60) -> some View {
        modifier(Celebrate(trigger: trigger, intensity: intensity))
    }
}
