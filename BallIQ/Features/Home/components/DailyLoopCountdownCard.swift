import SwiftUI

/// Home's post-completion "come back tomorrow" moment: once both dailies are done for the day,
/// this replaces the sell of "tap to play" with a countdown + streak-at-stake framing, plus a
/// nudge toward the arcade formats so there's still something to do today. The countdown math
/// lives in `HomeDailyLoop` (pure, unit-tested); this view just re-renders it once a second via
/// `TimelineView`, so the timer only runs while this card is actually on screen.
struct DailyLoopCountdownCard: View {
    let streak: Int
    /// Passed in rather than hardcoded so this view stays a pure render of whatever Home
    /// decides counts as "arcade filler" — see `GameFormat.arcade`.
    let arcadeFormats: [GameFormat]
    let launch: (GameFormat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            countdownBlock
            arcadeNudge
        }
    }

    private var countdownBlock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let target = HomeDailyLoop.nextUTCMidnight(after: context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 18, weight: .black))
                    Text(HomeDailyLoop.streakFraming(streak: streak).uppercased())
                        .font(.heading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(HomeDailyLoop.countdownString(now: context.date, target: target))
                    .font(.hero(46))
                    .monospacedDigit()
                Text("NEXT DAILY AT MIDNIGHT UTC")
                    .font(.label11)
                    .opacity(0.75)
            }
            .foregroundStyle(Color.onVolt)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .blockCard(fill: .voltFill)
    }

    private var arcadeNudge: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("While you wait")
                .font(.heading)
                .textCase(.uppercase)
                .foregroundStyle(Color.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(arcadeFormats) { format in
                        FormatGridItem(format: format) { launch(format) }
                            .frame(width: 132)
                    }
                }
                // Lets the last card's shadow render without the scroll view clipping it.
                .padding(.trailing, 2)
            }
        }
    }
}

#Preview {
    VStack {
        DailyLoopCountdownCard(streak: 4, arcadeFormats: GameFormat.arcade, launch: { _ in })
        DailyLoopCountdownCard(streak: 0, arcadeFormats: GameFormat.arcade, launch: { _ in })
    }
    .padding(16)
    .background(Color.appBackground)
}
