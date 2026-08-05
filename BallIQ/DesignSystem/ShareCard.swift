import SwiftUI

/// Shared Prime Time frame for every rendered share card (M13 pattern: ink border, hard ledge,
/// fixed 320pt width). Extracted after `ShareCardView`, `DraftSpinShareCardView`,
/// `ProfileShareCardView` and `PuzzlePreviewCardView` had each hand-copied this ~15-line frame —
/// every share card (including the Grid/Over-Under/Who Am I? ones added alongside this) wraps
/// its own header/body/footer stack in this instead.
struct ShareCardFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(width: 320)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.borderInk, lineWidth: 2.5)
            )
            .padding(6)   // room for the ledge in the rendered image
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.borderInk)
                    .offset(x: 4, y: 4)
                    .padding(6)
            )
    }
}

/// The "PLAY AT PLAYBOOK" ledge every share card ends on.
struct ShareCardFooter: View {
    var body: some View {
        Text("PLAY AT PLAYBOOK")
            .font(.custom(FontName.condBold, size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceMuted)
    }
}

/// A share card's colored header band: wordmark + kicker label, static gold treatment when the
/// result is the rare/perfect one (mirrors the in-app hero's `.voltFill` convention — foil's
/// animated shimmer can't survive a static `ImageRenderer` snapshot, but the gold fill and a
/// baked-in diagonal sheen read as "special" in a still image too).
struct ShareCardHeaderBand<Content: View>: View {
    var rare: Bool = false
    @ViewBuilder let content: Content

    private var fill: Color { rare ? .voltFill : .accentFill }
    private var ink: Color { rare ? .onVolt : .onAccent }

    var body: some View {
        content
            .environment(\.shareCardInk, ink)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .overlay(alignment: .topTrailing) {
                if rare {
                    // A baked-in diagonal sheen — the closest a static render gets to Foil's
                    // shimmer — so a perfect result still reads as "rare" once screenshotted.
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)],
                                  startPoint: .topTrailing, endPoint: .center)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct ShareCardInkKey: EnvironmentKey {
    static let defaultValue: Color = .onAccent
}

extension EnvironmentValues {
    /// The header band's ink color, threaded down so header content doesn't have to re-derive
    /// `rare ? .onVolt : .onAccent` itself.
    var shareCardInk: Color {
        get { self[ShareCardInkKey.self] }
        set { self[ShareCardInkKey.self] = newValue }
    }
}

extension View {
    /// Render any view to a SwiftUI `Image` for `ShareLink`/`SharePreview` — the `rendered()`
    /// method every share card duplicated.
    @MainActor
    func renderedForShare(scale: CGFloat = 3) -> Image {
        let renderer = ImageRenderer(content: self)
        renderer.scale = scale
        if let ui = renderer.uiImage { return Image(uiImage: ui) }
        return Image(systemName: "square.dashed")
    }
}
