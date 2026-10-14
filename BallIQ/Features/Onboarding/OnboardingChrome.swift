import SwiftUI

/// Shared furniture for the five onboarding slides, so each slide file only owns its content and
/// the flow reads as one designed sequence rather than five screens that happen to follow each
/// other. All of it is arcade-pop vocabulary from DESIGN.md turned up: ink outlines, hard ledge
/// shadows, a colour block per slide, stickers that land with an overshoot.
///
/// None of these are measuring containers — see `OnboardingView.fitsOrScrolls` for why that
/// matters on iPad. `SpeedLines` measures internally, but only ever as a background layer.

// MARK: - Progress

/// Chunky segmented progress: one ink-outlined pill per slide, filled in volt up to the current
/// one. The current segment is wider so "where am I" reads at a glance.
struct OnboardingProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Color.voltFill : Color.surface1)
                    .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 2))
                    .frame(width: i == current ? 34 : 16, height: 10)
            }
        }
        .animation(Motion.overshoot, value: current)
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(total)"))
    }
}

// MARK: - CTA

/// The one primary button every slide ends on: condensed caps on a colour block, ink border and
/// a hard ledge that the press pushes the button down onto — a physical "click" rather than the
/// app-wide 3% scale, because this is the button a brand-new player presses five times in a row.
struct OnboardingCTA: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var loading = false
    var fill: Color = .accentFill
    var on: Color = .onAccent
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.medium)
            action()
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    if loading { ProgressView().tint(on) }
                    Text(title).font(.custom(FontName.condBlack, size: 21))
                }
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.label11)
                        .lineLimit(1)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(on)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(LedgePressStyle(fill: fill))
    }
}

/// Button face sits `lift` above an ink slab; pressing drops it onto the slab.
struct LedgePressStyle: ButtonStyle {
    var fill: Color
    var lift: CGFloat = 5
    var radius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Color.borderInk, lineWidth: 2.5))
            .offset(x: pressed ? lift : 0, y: pressed ? lift : 0)
            .background(shape.fill(Color.borderInk).offset(x: lift, y: lift))
            .animation(Motion.snap, value: pressed)
    }
}

// MARK: - Backdrop

extension View {
    /// Paper ground plus a tilted colour block across the top third, with speed lines and a glow
    /// in it — the splash screen's energy carried into every slide, recoloured per slide.
    func slideBackdrop(_ tint: Color, height: CGFloat = 300) -> some View {
        background(alignment: .top) {
            ZStack(alignment: .top) {
                DiagonalBlock(cut: 56)
                    .fill(tint)
                    .overlay(SpeedLines(color: .white, opacity: 0.09, spacing: 26).clipShape(DiagonalBlock(cut: 56)))
                    .frame(height: height)
                DiagonalBlock(cut: 56)
                    .stroke(Color.borderInk, lineWidth: 3)
                    .frame(height: height)
                HeroGlow(color: .white)
                    .frame(width: 360, height: 360)
                    .offset(y: -60)
                    .blendMode(.softLight)
            }
            .ignoresSafeArea(edges: .top)
            .animation(Motion.easeOut, value: tint)
        }
        .paperGround()
    }
}

// MARK: - Stamp

/// A rotated sticker label — "LOCKED IN", "NEW", "FREE" — that slams in with an overshoot.
struct PopStamp: View {
    let text: LocalizedStringKey
    var fill: Color = .voltFill
    var on: Color = .onVolt
    var angle: Double = -8
    var size: CGFloat = 16

    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.custom(FontName.condBlack, size: size))
            .foregroundStyle(on)
            .padding(.horizontal, size * 0.6)
            .padding(.vertical, size * 0.25)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.borderInk).offset(x: 3, y: 3)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.borderInk, lineWidth: 2)
                }
            )
            .rotationEffect(.degrees(angle))
            .scaleEffect(landed || reduceMotion ? 1 : 2.2)
            .opacity(landed || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.overshoot.delay(0.15)) { landed = true }
            }
    }
}

#Preview {
    VStack(spacing: 30) {
        OnboardingProgress(current: 2, total: 5)
        PopStamp(text: "FREE")
        OnboardingCTA(title: "LET'S GO") {}
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .slideBackdrop(.accentFill)
}
