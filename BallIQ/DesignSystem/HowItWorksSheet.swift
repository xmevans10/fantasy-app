import SwiftUI

/// Shared "How it works" explainer — the competitive-surface counterpart of Keep4's
/// `ScoringDetailSheet`, generalized: icon-in-tinted-square header, card-surface rule
/// rows, optional tinted callout panel, muted info footnote. Leagues, Versus, and the
/// Daily Draft instantiate this with copy only; the layout lives here once so the three
/// explainers can't drift apart visually.
struct HowItWorksSheet: View {
    struct Rule: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    /// One emphasized panel for the rule that deserves more than a row — e.g. Leagues'
    /// promote/relegate zones, Versus' forfeit clock.
    struct Callout {
        let symbol: String
        let label: String
        let text: String
        let tint: Color
        let background: Color
    }

    let title: String
    let intro: String
    let symbol: String
    let tint: Color
    let tintBackground: Color
    let rules: [Rule]
    var kicker: String = "How it works"
    var callout: Callout? = nil
    var footnote: String? = nil
    /// Screenshot runs start expanded so every rule is capturable without a drag
    /// (same pattern as `ScoringDetailSheet`).
    var startExpanded: Bool = false

    @State private var detent: PresentationDetent = .medium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                rulesCard
                if let callout { calloutPanel(callout) }
                if let footnote { footnoteRow(footnote) }
            }
            .padding(20)
            .padding(.top, 10)
            .padding(.bottom, 16)   // keep the footnote clear of the home indicator
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear { if startExpanded { detent = .large } }
    }

    /// One-shot auto-present gate: true the first time a surface asks, false forever
    /// after (per-feature UserDefaults flag). Call from the surface's `onAppear`.
    static func shouldAutoPresent(feature: String, defaults: UserDefaults = .standard) -> Bool {
        let key = "howItWorksSeen_\(feature)"
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tintBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(kicker)
                        .textCase(.uppercase)
                        .font(.label11)
                        .kerning(1)
                        .foregroundStyle(Color.textMuted)
                    Text(title)
                        .textCase(.uppercase)
                        .font(.title)
                        .foregroundStyle(Color.textPrimary)
                }
            }
            Text(intro)
                .font(.body14)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rules

    private var rulesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in
                if i > 0 {
                    Rectangle().fill(Color.hairline).frame(height: Hairline.width)
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: rule.symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.title)
                            .font(.bodyStrong)
                            .foregroundStyle(Color.textPrimary)
                        Text(rule.detail)
                            .font(.body14)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .cardSurface()
    }

    // MARK: - Callout / footnote

    private func calloutPanel(_ callout: Callout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(callout.label, systemImage: callout.symbol)
                .textCase(.uppercase)
                .font(.label12)
                .foregroundStyle(callout.tint)
            Text(callout.text)
                .font(.body14)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(callout.background)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func footnoteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .bold))
                .padding(.top, 2)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.label12)
        .foregroundStyle(Color.textMuted)
    }
}
