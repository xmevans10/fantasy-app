import SwiftUI

struct WhoAmIResultView: View {
    let puzzle: WhoAmIPuzzle
    let result: WhoAmIScoring.Result
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onDone: () -> Void

    @State private var confetti = 0

    private var heroFill: Color { result.solved ? (result.cluesUsed == 1 ? .voltFill : .accentFill) : .surface1 }
    private var heroInk: Color { result.solved ? (result.cluesUsed == 1 ? .onVolt : .onAccent) : .textPrimary }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(1) }
                    answerCard.heroReveal(2)
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: result.cluesUsed == 1 ? 90 : 50)
        .onAppear { if result.solved { confetti += 1 } }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(result.solved ? (result.cluesUsed == 1 ? "FIRST-CLUE GENIUS" : "SOLVED") : "OUT OF GUESSES")
                .font(.heading)
                .foregroundStyle(heroInk.opacity(0.85))

            CountUpText(value: result.total, font: .heroNumber, color: heroInk)

            Text(result.solved ? "SOLVED ON CLUE \(result.cluesUsed)" : "BETTER LUCK TOMORROW")
                .font(.label12)
                .foregroundStyle(heroInk.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: heroFill)
    }

    /// Header-band + headshot-badge shape (silhouette placeholder — WhoAmI's content has no
    /// photo URL) so the reveal reads as the same "player card" language every other
    /// minigame's result screen already uses, instead of plain stacked text.
    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PlayerHeadshotBadge(headshot: nil, tint: Color.onAccent, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("THE ANSWER WAS")
                        .font(.label11)
                        .foregroundStyle(Color.onAccent.opacity(0.75))
                    Text(puzzle.answer.canonical)
                        .font(.custom(FontName.condBlack, size: 20))
                        .foregroundStyle(Color.onAccent)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color.accentFill)
            Text(puzzle.sport.displayName)
                .font(.label11)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
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

/// Shared rating / XP / streak summary shown on result screens.
struct RewardsRow: View {
    let rewards: RepositoryContainer.SessionRewards

    var body: some View {
        let change = rewards.ratingChange
        let up = change.delta >= 0
        return HStack(spacing: 16) {
            metric(label: "Rating", value: "\(change.new)",
                   accent: "\(up ? "+" : "")\(change.delta)",
                   accentColor: up ? .successText : .dangerText)
            Divider().frame(height: 32)
            metric(label: "XP", value: "+\(rewards.xpEarned)", accent: nil, accentColor: .textMuted)
            Divider().frame(height: 32)
            metric(label: "Streak", value: "\(rewards.newStreak)", accent: nil, accentColor: .textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface()
    }

    private func metric(label: String, value: String, accent: String?, accentColor: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.hero(20)).foregroundStyle(Color.textPrimary)
                if let accent { Text(accent).font(.label12).foregroundStyle(accentColor) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
