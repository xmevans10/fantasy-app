import SwiftUI

/// The head-to-head verdict shown when a run was opened from someone's challenge link.
///
/// Shared by every challengeable format rather than reimplemented per result screen — the two
/// result views differ in what a "hit" is (cells solved vs correct picks) and in nothing else
/// that matters here, and `ChallengeLink` already carries the unit as `hits`/`outOf`.
struct ChallengeResultBanner: View {
    let challenge: ChallengeLink
    /// This run's hits, in the same unit as `challenge.outOf`.
    let hits: Int
    let score: Int

    private var outcome: ChallengeLink.Outcome {
        challenge.outcome(hits: hits, score: score)
    }

    /// A win is the volt moment; a loss stays on the neutral surface rather than going red.
    /// Losing a friendly dare is the hook that makes someone play again tomorrow — dressing it
    /// as a failure state is how you lose them instead.
    private var fill: Color {
        switch outcome {
        case .win:  return .voltFill
        case .tie:  return .accentFill
        case .loss: return .surface1
        }
    }

    private var ink: Color {
        switch outcome {
        case .win:  return .onVolt
        case .tie:  return .onAccent
        case .loss: return .textPrimary
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(outcome.verdict)
                .font(.heading)
                .foregroundStyle(ink.opacity(0.85))

            HStack(spacing: 0) {
                side(label: "YOU", hits: hits, emphasised: outcome != .loss)
                Rectangle().fill(ink.opacity(0.25))
                    .frame(width: Hairline.width, height: 40)
                side(label: (challenge.challenger ?? "THEM").uppercased(),
                     hits: challenge.hits, emphasised: outcome != .win)
            }

            Text(tagline)
                .font(.label12)
                .foregroundStyle(ink.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .blockCard(fill: fill)
    }

    private func side(label: String, hits: Int, emphasised: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.label11)
                .foregroundStyle(ink.opacity(0.7))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("\(hits)/\(challenge.outOf)")
                .font(.hero(34))
                .foregroundStyle(ink.opacity(emphasised ? 1 : 0.55))
        }
        .frame(maxWidth: .infinity)
    }

    /// Names the tiebreak explicitly when points decided it — otherwise a 7/9 losing to a 7/9
    /// reads as a bug.
    private var tagline: String {
        let name = challenge.challenger ?? "They"
        switch outcome {
        case .win where hits == challenge.hits:
            return "Same board, same score — you won it on points."
        case .loss where hits == challenge.hits:
            return "Same board, same score — \(name) won it on points."
        case .win:  return "You beat \(name) on the same board."
        // Deliberately doesn't open with the name: usernames are lowercase far more often than
        // not, and "alex beat you…" reads as a typo. Mid-sentence (the cases above) it's fine,
        // and the column header right above already says who they are.
        case .loss: return "Beaten on the same board. Rematch tomorrow."
        case .tie:  return "Dead even, right down to the points."
        }
    }
}
