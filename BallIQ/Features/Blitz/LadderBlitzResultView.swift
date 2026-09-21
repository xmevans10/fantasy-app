import SwiftUI

/// The end of a ladder blitz rung — the head-to-head, and the answers.
///
/// Deliberately not `BlitzResultView`: that screen is built around a personal best and a local
/// high score, neither of which a rung has — the comparable is a bot, not your last run. What the
/// two share is `BlitzRoundList`, because "what were the answers, and did I get them" is the same
/// question on both screens (AGENTS.md §4).
///
/// **The score is compared on points, not hits**, since a blitz run aggregates boards of different
/// formats and sizes. Ties go to the player, matching `LadderOutcome` and the single-board ladder.
struct LadderBlitzResultView: View {
    let outcome: LadderBlitzOutcome
    let summary: BlitzRunSummary
    /// True when the player left a board rather than playing the clock down — changes only the
    /// loss headline, the same distinction the arcade screen makes.
    var endedEarly: Bool = false
    let onRematch: () -> Void
    let onDone: () -> Void

    @State private var confetti = 0

    /// A win is the volt moment; a loss stays on the neutral surface rather than going red —
    /// losing a rung is an invitation to rematch, not a failure state.
    private var fill: Color { outcome.won ? .voltFill : .surface1 }
    private var ink: Color { outcome.won ? .onVolt : .textPrimary }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    header.heroReveal(0)
                    if !summary.rounds.isEmpty || summary.cutOff != nil {
                        BlitzRoundList(summary: summary).heroReveal(1)
                    }
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: outcome.won ? 80 : 30)
        .onAppear { if outcome.won { confetti += 1 } }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(headline).font(.heading).foregroundStyle(ink.opacity(0.85))

            HStack(spacing: 0) {
                side(label: "YOU", points: outcome.myPoints, emphasised: outcome.won)
                Rectangle().fill(ink.opacity(0.25))
                    .frame(width: Hairline.width, height: 40)
                side(label: outcome.botName.uppercased(), points: outcome.botPoints,
                     emphasised: !outcome.won)
            }

            Text(tagline)
                .font(.label12)
                .foregroundStyle(ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .blockCard(fill: fill)
    }

    private var headline: String {
        guard outcome.won else {
            return endedEarly ? String(localized: "RUN ENDED") : String(localized: "YOU LOST")
        }
        if let advanced = outcome.advancedTo {
            return String(localized: "RUNG CLEARED · RUNG \(advanced) UNLOCKED")
        }
        // Won on a rung already cleared: beating it again banks the run but advances nothing.
        return String(localized: "YOU WIN")
    }

    private var tagline: String {
        let boards = summary.played == 1
            ? String(localized: "1 puzzle")
            : String(localized: "\(summary.played) puzzles")
        if outcome.won {
            return String(localized: "\(boards) in \(summary.config.duration.minutes) minutes — you outscored \(outcome.botName).")
        }
        return String(localized: "\(outcome.botName) outscored you over the same \(boards). Rematch for a fresh set.")
    }

    private func side(label: String, points: Int, emphasised: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.label11)
                .foregroundStyle(ink.opacity(0.7))
                .lineLimit(1).minimumScaleFactor(0.6)
            CountUpText(value: points, font: .hero(34), color: ink.opacity(emphasised ? 1 : 0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            HStack(spacing: 10) {
                Button(action: onDone) {
                    Text("DONE")
                        .font(.heading)
                        .foregroundStyle(Color.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)

                Button(action: onRematch) {
                    Text("REMATCH").ctaLabel()
                }
                .buttonStyle(PrimePressStyle())
            }
            .padding(16)
            .background(Color.surface)
        }
    }
}
