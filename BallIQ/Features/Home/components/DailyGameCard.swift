import SwiftUI

/// A "today's daily game" card — a broadcast "matchup" block with a colored header band.
struct DailyGameCard: View {
    let formatName: String
    let symbol: String
    let sport: Sport
    let title: String
    let subtitle: String
    /// Optional author's note (community puzzles) — shown as a second line under the subtitle.
    var description: String? = nil
    /// Optional grading-philosophy badge (PPR / era-adjusted / author's call) in the header band.
    var scoring: ScoringKind? = nil
    /// Optional grain badge (Season / Single Game / Career) in the header band. nil for
    /// Who Am I? cards, which have no grain concept.
    var grain: PuzzleGrain? = nil
    let completed: Bool
    var accent: Color = .accentFill
    var onAccent: Color = .onAccent
    /// Card body fill — community cards pass a warm tint to read "hand-made" vs the daily white.
    var bodyFill: Color = .surface1
    let action: () -> Void
    /// Optional secondary action — an explicit overflow icon in the header band, distinct from
    /// the card's primary tap-to-play. nil (default) hides it; only Community cards pass one
    /// (report puzzle). A nested `Button` here works cleanly since its tap frame (a small icon in
    /// the header) never overlaps the rest of the card's tap area.
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Colored header band. The info portion (icon/format/badges) is combined into
                // one VoiceOver stop; the overflow button stays a separate, independently
                // reachable element rather than getting swallowed into that combined label.
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: symbol)
                        Text(formatName.uppercased())
                            .font(.heading)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer()
                        if let scoring {
                            HStack(spacing: 4) {
                                Image(systemName: scoring.symbol).font(.system(size: 9, weight: .bold))
                                Text(scoring.badgeLabel(for: sport)).font(.label11).lineLimit(1)
                            }
                            .fixedSize()   // never wrap mid-capsule; the title compresses instead
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(onAccent.opacity(0.18))
                            .clipShape(Capsule())
                        }
                        if let grain {
                            HStack(spacing: 4) {
                                Image(systemName: grain.symbol).font(.system(size: 9, weight: .bold))
                                Text(grain.badgeLabel).font(.label11).lineLimit(1)
                            }
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(onAccent.opacity(0.18))
                            .clipShape(Capsule())
                        }
                        Text(sport.displayName)
                            .font(.label11)
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(onAccent.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .accessibilityElement(children: .combine)
                    if let secondaryAction {
                        Button(action: secondaryAction) {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More options")
                    }
                }
                .foregroundStyle(onAccent)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent)

                // Body
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle.uppercased())
                            .font(.label11)
                            .foregroundStyle(Color.textMuted)
                        if let description, !description.isEmpty {
                            Text(description)
                                .font(.body14)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if completed {
                        Label("DONE", systemImage: "checkmark.circle.fill")
                            .font(.label12)
                            .foregroundStyle(Color.successText)
                    } else {
                        Text("PLAY")
                            .font(.heading)
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Color.accentFill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(bodyFill)
                .accessibilityElement(children: .combine)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.borderInk, lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 0, x: 0, y: 4)
        }
        .buttonStyle(PrimePressStyle())
    }
}
