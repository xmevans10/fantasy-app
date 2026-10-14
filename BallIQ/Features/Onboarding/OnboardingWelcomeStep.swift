import SwiftUI

/// Introduces the daily sports puzzles before asking the player to pick a sport.
struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                hero
                    .padding(.top, Space.sm)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            OnboardingCTA(title: "LET'S GO", action: onContinue)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 18) {
            wordmarkChip

            VStack(spacing: 10) {
                stackedHeadline
                Text("Daily sports puzzles built from real player seasons. Rank them, guess them, draft them, then climb the ladder.")
                    .font(.body14)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PopStamp(text: "DAILY · FREE", fill: .voltFill, on: .onVolt, angle: -6, size: 15)
        }
        .heroReveal(0)
    }

    /// The wordmark's "play" half renders in ink, which vanishes on the blue block — rather than
    /// touch `Wordmark` itself (used everywhere else against paper), it sits on its own small
    /// white sticker chip here, the same ink-outline-plus-ledge language as `PopStamp`.
    private var wordmarkChip: some View {
        Wordmark(size: 22)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.borderInk).offset(x: 3, y: 3)
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.borderInk, lineWidth: 2)
                }
            )
            .rotationEffect(.degrees(-3))
    }

    /// Sits below the backdrop's colour block, on paper — so ink, not white (white rendered
    /// invisible on cream in the first pass).
    ///
    /// Three huge stacked lines instead of one sentence-case headline — the loudest read on the
    /// screen, with "BALL" broken out onto its own tilted, ink-outlined volt sticker so the one
    /// word that matters lands like a stamp rather than just being the last word of a sentence.
    private var stackedHeadline: some View {
        VStack(spacing: 2) {
            Text("PROVE")
                .font(.hero(44))
                .foregroundStyle(Color.textPrimary)
            Text("YOU KNOW")
                .font(.hero(44))
                .foregroundStyle(Color.textPrimary)
            Text("BALL")
                .font(.hero(46))
                .foregroundStyle(Color.onVolt)
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.borderInk).offset(x: 4, y: 4)
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.voltFill)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.borderInk, lineWidth: 2.5)
                    }
                )
                .rotationEffect(.degrees(-4))
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
    }

}

#Preview {
    OnboardingWelcomeStep(onContinue: {})
}
