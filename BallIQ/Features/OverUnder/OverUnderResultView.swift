import SwiftUI

struct OverUnderResultView: View {
    let sport: Sport
    let score: Int
    let correctCount: Int
    let wrongCount: Int
    let highScore: Int
    let beatHighScore: Bool
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @State private var confetti = 0
    @State private var showPaywall = false
    @State private var showLeaderboard = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    leaderboardEntry.heroReveal(1)
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(2) }
                    if !container.entitlements.hasUnlimitedOverUnderLives {
                        livesUpsell.heroReveal(3)
                    }
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: beatHighScore ? 90 : 40)
        .onAppear {
            let gained = (rewards?.ratingChange.delta ?? 0) > 0
            if beatHighScore || gained { confetti += 1 }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(container)
        }
        .sheet(isPresented: $showLeaderboard) {
            ArcadeLeaderboardView(game: .overUnder, sport: sport)
                .environmentObject(container)
        }
    }

    private var leaderboardEntry: some View {
        ArcadeLeaderboardEntryRow(caption: "THIS WEEK'S TOP OVER/UNDER RUNS") {
            showLeaderboard = true
        }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(beatHighScore ? "NEW HIGH SCORE" : "OUT OF LIVES")
                .font(.heading)
                .foregroundStyle((beatHighScore ? Color.onVolt : Color.onAccent).opacity(0.85))
            CountUpText(value: score, font: .heroNumber, color: beatHighScore ? .onVolt : .onAccent)
            Text("\(correctCount) RIGHT · \(wrongCount) WRONG")
                .font(.label12)
                .foregroundStyle((beatHighScore ? Color.onVolt : Color.onAccent).opacity(0.75))
            if !beatHighScore {
                Text("BEST: \(highScore)")
                    .font(.label11)
                    .foregroundStyle((beatHighScore ? Color.onVolt : Color.onAccent).opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: beatHighScore ? .voltFill : .accentFill)
    }

    private var livesUpsell: some View {
        Button { showPaywall = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "infinity")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.proText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Never wait for lives").font(.title).foregroundStyle(Color.textPrimary)
                    Text("PRO GETS UNLIMITED OVER/UNDER").font(.label11).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .cardSurface()
        }
        .buttonStyle(PrimePressStyle())
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            Button(action: onDone) {
                Text("DONE")
                    .font(.heading)
                    .foregroundStyle(Color.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(Color.surface)
        }
    }
}
