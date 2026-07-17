import SwiftUI
import CoreMotion

/// Shared device-tilt source for the foil shimmer. One `CMMotionManager` is reference-counted
/// across all active foils (typically just one card) and stops when none are on screen. On the
/// simulator device motion is unavailable, so roll/pitch stay 0 and the time drift carries the
/// effect — the overlay still renders for screenshots.
@MainActor
final class FoilMotion: ObservableObject {
    static let shared = FoilMotion()

    private let manager = CMMotionManager()
    private var subscribers = 0
    @Published var roll: Double = 0
    @Published var pitch: Double = 0

    private init() { manager.deviceMotionUpdateInterval = 1.0 / 30.0 }

    func subscribe() {
        subscribers += 1
        guard subscribers == 1, manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let a = motion?.attitude else { return }
            self.roll = a.roll
            self.pitch = a.pitch
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { manager.stopDeviceMotionUpdates() }
    }
}

/// Balatro-style holographic "foil" treatment: a rainbow `AngularGradient` overlaid on the card
/// with `.blendMode(.overlay)`, its sweep driven by device tilt (CoreMotion) plus a gentle time
/// drift so it's alive even when the phone is still. A delight treatment for a single "rare" card.
/// Gated on Reduce Motion (renders the card untouched, never starts the motion manager).
struct Foil: ViewModifier {
    var active: Bool
    /// The sheen is clipped to this shape — a rounded rect for cards, `DiagonalBlock` for
    /// the lower-third banners. Any shape works; it just needs to match the view's own clip.
    var shape: AnyShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = FoilMotion.shared

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    TimelineView(.animation) { timeline in
                        sheen(at: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                .onAppear { motion.subscribe() }
                .onDisappear { motion.unsubscribe() }
        } else {
            content
        }
    }

    /// The rainbow sweep at time `t`. Tilt shifts the gradient's center and angle; the slow
    /// time drift keeps it shimmering when the device is held still.
    private func sheen(at t: TimeInterval) -> some View {
        let drift = Angle(degrees: t.truncatingRemainder(dividingBy: 7) / 7 * 360)
        let tilt = Angle(radians: motion.roll * 1.2 + motion.pitch * 0.6)
        let center = UnitPoint(x: 0.5 + CGFloat(sin(motion.roll)) * 0.35,
                               y: 0.5 + CGFloat(sin(motion.pitch)) * 0.35)
        return shape
            .fill(AngularGradient(gradient: Self.rainbow, center: center, angle: drift + tilt))
            .blendMode(.overlay)
            .opacity(0.5)
            .allowsHitTesting(false)
    }

    private static let rainbow = Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6.0)
        .map { Color(hue: $0, saturation: 0.85, brightness: 1.0) })
}

extension View {
    /// Apply a holographic "foil" shimmer (see `Foil`). `cornerRadius` should match the card's
    /// own clip so the sheen stays within its rounded bounds.
    func foil(active: Bool, cornerRadius: CGFloat = 14) -> some View {
        modifier(Foil(active: active,
                      shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))))
    }

    /// Foil clipped to an arbitrary shape (e.g. the lower-third banners' `DiagonalBlock`).
    func foil(active: Bool, in shape: some Shape) -> some View {
        modifier(Foil(active: active, shape: AnyShape(shape)))
    }
}
