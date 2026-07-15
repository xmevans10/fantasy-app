import SwiftUI

// Shared "Prime Time" controls — one segmented control, one empty state, one CTA treatment,
// one press feedback. Screens compose these instead of hand-rolling per-screen variants.

/// Broadcast segmented control — surfaceMuted track, accentFill active segment, condensed caps.
/// Replaces stock `.pickerStyle(.segmented)` so every screen shares the same switch.
struct PrimeSegmentedControl<Value: Hashable>: View {
    let options: [(title: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let active = selection == option.value
                Button {
                    guard !active else { return }
                    withAnimation(Motion.snap) { selection = option.value }
                    Haptics.tap()
                } label: {
                    Text(option.title.uppercased())
                        .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 14))
                        .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(active ? Color.accentFill : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// Shared filter chip — condensed caps, capsule shape, accent/muted fill. The one pill
/// style for sport/decade/position/sort filters app-wide (previously three near-duplicate
/// local implementations across Browse, Community, and the Create flow had each drifted
/// slightly on font/shape). Wrap a row of these in `ScrollView(.horizontal)` — never a
/// bare `HStack` — so the row can't silently overflow/clip as option lists grow (e.g. a
/// new sport).
struct PrimeChip: View {
    let label: String
    let active: Bool
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: { action(); Haptics.tap() }) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                }
                Text(label.uppercased())
                    .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 14))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(active ? Color.accentFill : Color.surfaceMuted)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Compact "Label ▾" dropdown — a native `Menu` (well-tested tap-to-reveal option list,
/// not a hand-rolled popover) behind a Prime Time capsule trigger. Replaces an
/// always-expanded row of `PrimeChip`s for filter axes with many options (sport, decade,
/// sort): the row collapses to one line when idle instead of showing every choice at
/// once. Quiet/muted when `selection` is the default value, accent-tinted when it isn't,
/// so filter state stays visible at a glance even though the options themselves are hidden.
struct PrimeDropdown<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    /// Whether `selection` counts as "no filter applied" — controls the quiet vs
    /// accent-tinted trigger style. Defaults to comparing against `options.first`.
    var isDefault: ((Value) -> Bool)? = nil

    private var active: Bool { !(isDefault?(selection) ?? (selection == options.first)) }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                    Haptics.tap()
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title(selection).uppercased())
                    .font(.custom(active ? FontName.condBlack : FontName.condBold, size: 14))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(active ? Color.accentFill : Color.surfaceMuted)
            .clipShape(Capsule())
        }
    }
}

/// Shared empty / sign-in / error state: badge glyph, condensed title, muted message,
/// optional CTA. Centers itself in whatever container it's given.
struct EmptyStateView: View {
    let symbol: String
    // LocalizedStringKey (not String) so every call site's literal/ternary/interpolated
    // title-message-actionTitle extracts into Localizable.xcstrings automatically — the
    // 19 call sites across the app all pass compile-time literals, so this costs them
    // nothing, but it's why we can't accept an arbitrary already-computed String here.
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.accentText)
                .frame(width: 84, height: 84)
                .background(Color.accentBg)
                .clipShape(Circle())
            Text(title)
                .textCase(.uppercase)
                .font(.title)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body14)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .textCase(.uppercase)
                        .font(.heading)
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 26).padding(.vertical, 11)
                        .background(Color.accentFill)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(PrimePressStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Quick scale-down press feedback — the arcade "button press" feel for cards and CTAs.
struct PrimePressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}

extension View {
    /// Full-width primary CTA treatment: condensed caps on a filled, rounded control.
    /// Apply to a Button/ShareLink *label*; pair with `PrimePressStyle` on the button itself.
    func ctaLabel(fill: Color = .accentFill, on: Color = .onAccent) -> some View {
        self.font(.heading)
            .foregroundStyle(on)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
