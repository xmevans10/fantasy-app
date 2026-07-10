import UIKit

/// Centralized haptics so feedback is consistent across formats.
enum Haptics {
    static func tap()    { impact(.light) }
    static func commit() { impact(.medium) }
    static func reject() { impact(.rigid) }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

/// Prepared soft-impact ticker for rapid sequences (slot reels, count-ups). The one-shot
/// `Haptics` helpers allocate a fresh generator per call — fine for isolated taps, but a
/// 20-tick reel run through them feels harsh and can drop ticks (each first impact pays
/// the Taptic Engine wake-up). This keeps ONE `.soft` generator warm (`prepare()` after
/// every tick, per Apple's guidance) and exposes per-tick `intensity`, so a spin can ramp
/// from a whisper to a thump as the reels decelerate instead of hammering uniform taps.
final class HapticTicker {
    private let generator = UIImpactFeedbackGenerator(style: .soft)

    func prepare() { generator.prepare() }

    /// `intensity` 0…1 — callers ramp this with their own animation curve.
    func tick(intensity: CGFloat = 0.6) {
        generator.impactOccurred(intensity: max(0, min(intensity, 1)))
        generator.prepare()
    }
}
