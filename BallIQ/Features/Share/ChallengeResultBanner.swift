import SwiftUI

/// Everything the head-to-head banner needs, independent of *where* the opponent came from.
///
/// Two things produce one: a `ChallengeLink` (the stateless, accountless share-sheet dare) and a
/// ladder rung (a bot solved on-device). They are genuinely different mechanics — one has a URL
/// and a share funnel, the other has a rung number and a skill level — but the verdict they
/// render is the same object: two numbers in the same unit, and who took it.
///
/// Extracted rather than letting the ladder grow a second banner, which would have drifted
/// (AGENTS.md §4). The `ChallengeLink` path is unchanged: `ChallengeResultBanner`'s original
/// initializer still takes a link and builds one of these.
struct DuelVerdict: Equatable {
    /// What to call the other side. "Alex", "The Rookie", or nil for a nameless challenger.
    let opponentName: String?
    let myHits: Int
    let theirHits: Int
    let outOf: Int
    /// Points, used only to break a tie on hits. Nil when the mechanic has no tiebreak — a
    /// ladder rung doesn't, because a tie against a bot goes to the player by design.
    let myScore: Int?
    let theirScore: Int?
    /// What the opponent says about the result, in their own voice. Nil when the opponent has
    /// no authored voice — a `ChallengeLink` challenger is a real person whose words we
    /// don't have, and silence is better than putting words in their mouth.
    var closingLine: String? = nil
    /// Whether a dead-even result is a win for the player. True on the ladder (you matched the
    /// machine; take it), false for a link challenge (a tie is a tie).
    let tieGoesToPlayer: Bool

    enum Outcome: Equatable {
        case win, loss, tie

        var verdict: String {
            switch self {
            case .win:  return "YOU WIN"
            case .loss: return "YOU LOST"
            case .tie:  return "DEAD HEAT"
            }
        }
    }

    var outcome: Outcome {
        if myHits != theirHits { return myHits > theirHits ? .win : .loss }
        if let myScore, let theirScore, myScore != theirScore {
            return myScore > theirScore ? .win : .loss
        }
        return tieGoesToPlayer ? .win : .tie
    }

    /// Whether the two sides landed on the same hit count — the banner names the tiebreak
    /// explicitly in that case, because a 7/9 losing to a 7/9 otherwise reads as a bug.
    var levelOnHits: Bool { myHits == theirHits }
}

/// The head-to-head verdict shown when a run was played against someone — a challenge link's
/// recorded score, or a ladder bot.
///
/// Shared by every challengeable format rather than reimplemented per result screen: the result
/// views differ in what a "hit" is (cells solved vs correct picks vs clue efficiency) and in
/// nothing else that matters here.
struct ChallengeResultBanner: View {
    let verdict: DuelVerdict

    /// The share-link path, unchanged. `ChallengeLink` already carries the unit as
    /// `hits`/`outOf`, so this is a straight lift.
    init(challenge: ChallengeLink, hits: Int, score: Int) {
        self.verdict = DuelVerdict(opponentName: challenge.challenger,
                                   myHits: hits, theirHits: challenge.hits,
                                   outOf: challenge.outOf,
                                   myScore: score, theirScore: challenge.score,
                                   closingLine: nil, tieGoesToPlayer: false)
    }

    init(verdict: DuelVerdict) { self.verdict = verdict }

    private var outcome: DuelVerdict.Outcome { verdict.outcome }

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
                side(label: "YOU", hits: verdict.myHits, emphasised: outcome != .loss)
                Rectangle().fill(ink.opacity(0.25))
                    .frame(width: Hairline.width, height: 40)
                side(label: (verdict.opponentName ?? "THEM").uppercased(),
                     hits: verdict.theirHits, emphasised: outcome != .win)
            }

            Text(tagline)
                .font(.label12)
                .foregroundStyle(ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // The opponent gets the last word. A named character reacting in their own voice is
            // most of what separates "you scored 6/8" from "you beat The Rookie".
            if let line = verdict.closingLine {
                Text("“\(line)”")
                    .font(.body14).italic()
                    .foregroundStyle(ink.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
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
            Text("\(hits)/\(verdict.outOf)")
                .font(.hero(34))
                .foregroundStyle(ink.opacity(emphasised ? 1 : 0.55))
        }
        .frame(maxWidth: .infinity)
    }

    /// Names the tiebreak explicitly when points decided it — otherwise a 7/9 losing to a 7/9
    /// reads as a bug.
    private var tagline: String {
        let name = verdict.opponentName ?? "They"
        switch outcome {
        case .win where verdict.levelOnHits && verdict.tieGoesToPlayer:
            return "Dead level with \(name), and a tie goes to you."
        case .win where verdict.levelOnHits:
            return "Same board, same score, you won it on points."
        case .loss where verdict.levelOnHits:
            return "Same board, same score, \(name) won it on points."
        case .win:  return "You beat \(name) on the same board."
        // Deliberately doesn't open with the name: usernames are lowercase far more often than
        // not, and "alex beat you…" reads as a typo. Mid-sentence (the cases above) it's fine,
        // and the column header right above already says who they are.
        case .loss: return "Beaten on the same board. Rematch tomorrow."
        case .tie:  return "Dead even, right down to the points."
        }
    }
}
