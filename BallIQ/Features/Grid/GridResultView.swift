import SwiftUI

struct GridResultView: View {
    let sport: Sport
    let score: Int
    let correctCount: Int
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onDone: () -> Void

    @State private var confetti = 0

    private var isPerfect: Bool { correctCount == 9 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(1) }
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: isPerfect ? 90 : 40)
        .onAppear { if isPerfect { confetti += 1 } }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(isPerfect ? "IMMACULATE GRID" : "GRID COMPLETE")
                .font(.heading)
                .foregroundStyle((isPerfect ? Color.onVolt : Color.onAccent).opacity(0.85))
            CountUpText(value: score, font: .heroNumber, color: isPerfect ? .onVolt : .onAccent)
            Text("\(correctCount) OF 9 CORRECT")
                .font(.label12)
                .foregroundStyle((isPerfect ? Color.onVolt : Color.onAccent).opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: isPerfect ? .voltFill : .accentFill)
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            Button(action: onDone) {
                Text("DONE").font(.heading).foregroundStyle(Color.accentText)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(Color.surface)
        }
    }
}
