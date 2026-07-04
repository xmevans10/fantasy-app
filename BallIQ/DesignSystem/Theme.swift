import SwiftUI

// MARK: - Color tokens — "Prime Time" (bright pop, sports-broadcast energy)
//
// Bright/light-first canvas with one dominant (electric blue) + one sharp accent (volt lime),
// neon semantics, ink type, and bold depth. Dark mode inverts to a bold night palette.
// Role tokens keep the M1 names (fill/bg/border/text/on) so views compile; values changed.
extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func dynamic(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    // MARK: Surfaces (bright paper canvas; bold night in dark mode)
    static let surface0 = dynamic(light: Color(hex: 0xF4F1E9), dark: Color(hex: 0x0E0C08)) // page
    static let surface1 = dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1A1611)) // card
    static let surface2 = dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x232019)) // panel
    static let surface3 = dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x2C281F)) // popover
    static let appBackground = surface0
    static let surface = surface1
    static let surfaceMuted = dynamic(light: Color(hex: 0xECE6D7), dark: Color(hex: 0x232019))

    // MARK: Ink / text
    static let ink = dynamic(light: Color(hex: 0x15120B), dark: Color(hex: 0xF4F1E9))
    static let textPrimary = ink
    static let textSecondary = dynamic(light: Color(hex: 0x57503F), dark: Color(hex: 0xCFC8B8))
    static let textMuted = dynamic(light: Color(hex: 0x8C8470), dark: Color(hex: 0x978E7C))
    static let textDisabled = dynamic(light: Color(hex: 0xB4AD9A), dark: Color(hex: 0x6A6354))

    // MARK: Borders — a hairline for subtle dividers, and an INK line for bold pop outlines
    static let hairline = dynamic(light: Color(hex: 0xE0D9C7), dark: Color(hex: 0x322E26))
    static let border = hairline
    static let borderStrong = dynamic(light: Color(hex: 0xC9C0AB), dark: Color(hex: 0x423D33))
    static let borderInk = dynamic(light: Color(hex: 0x15120B), dark: Color(hex: 0xF4F1E9))

    // MARK: accent — dominant "Prime" electric blue
    static let accentFill   = Color(hex: 0x1E50FF)
    static let onAccent     = Color.white
    static let accentText   = dynamic(light: Color(hex: 0x1A47E0), dark: Color(hex: 0x7C9CFF))
    static let accentBg     = dynamic(light: Color(hex: 0xE3E9FF), dark: Color(hex: 0x16224F))
    static let accentBorder = dynamic(light: Color(hex: 0x1E50FF), dark: Color(hex: 0x7C9CFF))

    // MARK: volt — sharp accent (lime). Highlights, streaks, emphasis.
    static let voltFill = Color(hex: 0xC2F03A)
    static let onVolt    = Color(hex: 0x15120B)
    static let voltText  = dynamic(light: Color(hex: 0x5C7A00), dark: Color(hex: 0xC2F03A))
    static let voltBg    = dynamic(light: Color(hex: 0xEEFAC4), dark: Color(hex: 0x2A3500))

    // MARK: success — neon green
    static let successFill = Color(hex: 0x18A957)
    static let onSuccess    = Color.white
    static let successText  = dynamic(light: Color(hex: 0x157F43), dark: Color(hex: 0x54E08A))
    static let successBg     = dynamic(light: Color(hex: 0xDDF5E5), dark: Color(hex: 0x0E2C19))

    // MARK: danger — neon red
    static let dangerFill = Color(hex: 0xE63A2E)
    static let onDanger    = Color.white
    static let dangerText  = dynamic(light: Color(hex: 0xC5251B), dark: Color(hex: 0xFF6E63))
    static let dangerBg     = dynamic(light: Color(hex: 0xFCE2E0), dark: Color(hex: 0x3A0F0B))

    // MARK: warning — hot flame orange (streak)
    static let warningFill = Color(hex: 0xFF8A1E)
    static let onWarning    = Color(hex: 0x2A1500)
    static let warningText  = dynamic(light: Color(hex: 0xB5560A), dark: Color(hex: 0xFFB163))
    static let warningBg     = dynamic(light: Color(hex: 0xFFEBD2), dark: Color(hex: 0x3A2200))

    // MARK: pro — purple
    static let proFill = Color(hex: 0x6D3BF5)
    static let onPro    = Color.white
    static let proText  = dynamic(light: Color(hex: 0x5A2CD6), dark: Color(hex: 0xB9A0FF))
    static let proBg     = dynamic(light: Color(hex: 0xEBE3FE), dark: Color(hex: 0x251744))

    // MARK: aliases kept for source compatibility
    static let brandBlue    = accentFill
    static let streakAmber  = warningFill
    static let successGreen = successFill
    static let dangerRed    = dangerFill
    static let proPurple    = proFill
}

// Typography lives in Typography.swift ("Prime Time" type system).

// MARK: - Shape tokens
enum Radius {
    static let card: CGFloat = 16
    static let control: CGFloat = 12
}

enum Hairline {
    static let width: CGFloat = 1
}

// MARK: - Surfaces & depth
//
// Prime Time uses bold depth: ink outlines + hard offset "ledge" shadows (sticker/comic pop),
// not soft blur. `cardSurface` is the everyday card; `blockCard` is the loud hero treatment.

struct CardSurface: ViewModifier {
    var radius: CGFloat = Radius.card
    func body(content: Content) -> some View {
        content
            .background(Color.surface1)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.borderStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 0, x: 0, y: 3) // hard ledge
    }
}

/// Loud "broadcast block" — colored fill, thick ink outline, hard offset shadow. For hero moments.
struct BlockCard: ViewModifier {
    var fill: Color = .surface1
    var radius: CGFloat = Radius.card
    var lift: CGFloat = 5
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.borderInk).offset(x: lift, y: lift)
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.borderInk, lineWidth: 2.5)
                }
            )
    }
}

extension View {
    func cardSurface(radius: CGFloat = Radius.card) -> some View {
        modifier(CardSurface(radius: radius))
    }
    func blockCard(fill: Color = .surface1, radius: CGFloat = Radius.card, lift: CGFloat = 5) -> some View {
        modifier(BlockCard(fill: fill, radius: radius, lift: lift))
    }
}

// MARK: - Wordmark
/// "play" + bold "book" in heavy condensed caps — broadcast bug.
struct Wordmark: View {
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: 0) {
            Text("play")
                .font(.custom(FontName.condBold, size: size))
                .foregroundStyle(Color.textPrimary)
            Text("book")
                .font(.custom(FontName.condBlack, size: size))
                .foregroundStyle(Color.accentFill)
        }
        .textCase(.lowercase)
    }
}
