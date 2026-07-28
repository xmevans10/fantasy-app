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

/// Balatro-style holographic "foil" treatment: a rainbow `AngularGradient` whose sweep is driven
/// by device tilt (CoreMotion) plus a gentle time drift, so it's alive even when the phone is
/// still. Gated on Reduce Motion (renders the content untouched, never starts the motion manager)
/// — anything relying on this for its *color* must therefore carry a static fallback fill of its
/// own, since under Reduce Motion this draws nothing at all.
struct Foil: ViewModifier {
    /// How the rainbow relates to what it covers. The distinction is which one owns the color.
    enum Style {
        /// A sheen *over* an existing fill: `.overlay` at half strength, so the base color still
        /// dominates and only shifts iridescently. For surfaces with art or a colour of their own
        /// to protect — `Keep4ResultView`'s rare card.
        case sheen
        /// The rainbow *is* the surface, drawn opaque. For elements with no colour of their own
        /// to preserve. `sheen` over a saturated base can never look like this: overlay blending
        /// keeps the base's hue by construction, which is why the lower-third banner read as gold
        /// with a faint shimmer rather than as a rainbow.
        case surface
    }

    var active: Bool
    var style: Style = .sheen
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
            .blendMode(style == .sheen ? .overlay : .normal)
            .opacity(style == .sheen ? 0.5 : 1)
            .allowsHitTesting(false)
    }

    /// Full hue circle. `through: 1.0` closes the loop on red so an `AngularGradient` has no seam
    /// where its sweep wraps.
    static let rainbow = Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6.0)
        .map { Color(hue: $0, saturation: 0.85, brightness: 1.0) })

    /// The same spectrum, standing still — what a `.surface` foil must fall back to under Reduce
    /// Motion, where the modifier itself draws nothing.
    static let staticRainbow = AngularGradient(gradient: rainbow, center: .center)
}

extension View {
    /// Apply a holographic "foil" shimmer (see `Foil`). `cornerRadius` should match the card's
    /// own clip so the sheen stays within its rounded bounds.
    func foil(active: Bool, style: Foil.Style = .sheen, cornerRadius: CGFloat = 14) -> some View {
        modifier(Foil(active: active, style: style,
                      shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))))
    }

    /// Foil clipped to an arbitrary shape (e.g. the lower-third banners' `DiagonalBlock`).
    func foil(active: Bool, style: Foil.Style = .sheen, in shape: some Shape) -> some View {
        modifier(Foil(active: active, style: style, shape: AnyShape(shape)))
    }
}
