import SwiftUI

struct Keep4ResultView: View {
    let puzzle: Keep4Puzzle
    let placement: [String: Pile]
    let result: Keep4Scoring.Result
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @State private var confetti = 0

    private var heroFill: Color { result.isPerfect ? .voltFill : .accentFill }
    private var heroInk: Color { result.isPerfect ? .onVolt : .onAccent }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    if let top = topSeason { foilCard(top).heroReveal(1) }
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(2) }
                    breakdown.heroReveal(3)
                    shareCardPreview.heroReveal(4)
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: result.isPerfect ? 90 : 40)
        .onAppear {
            let gained = (rewards?.ratingChange.delta ?? 0) > 0
            if result.isPerfect || gained { confetti += 1 }
        }
    }

    private var scoreHeader: some View {
        VStack(spacing: 4) {
            Text(result.isPerfect ? "PERFECT SORT" : "FINAL")
                .font(.heading)
                .foregroundStyle(heroInk.opacity(0.85))
            CountUpText(value: result.total, font: .heroNumber, color: heroInk)
            Text("\(result.correctCount) OF \(puzzle.players.count) CORRECT")
                .font(.label12)
                .foregroundStyle(heroInk.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .blockCard(fill: heroFill)
    }

    /// The single highest-graded season in the puzzle (always a correct Keep) — the "card of the
    /// round," highlighted with the holographic foil treatment as the one orchestrated sparkle.
    private var topSeason: PlayerSeason? {
        puzzle.players.max { $0.grade < $1.grade }
    }

    /// Grain-aware header: a career puzzle's best card is a career, not a season.
    private var topCardTitle: String {
        switch puzzle.puzzleGrain() {
        case .season:     return String(localized: "TOP SEASON")
        case .singleGame: return String(localized: "TOP GAME")
        case .career:     return String(localized: "TOP CAREER")
        }
    }

    private func foilCard(_ top: PlayerSeason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topCardTitle)
                .font(.heading)
                .foregroundStyle(Color.textPrimary)
            Keep4CardView(player: top,
                          sport: puzzle.sport,
                          assignment: placement[top.id],
                          revealCorrect: result.correctness[top.id],
                          foil: true,
                          gradeUnit: puzzle.scoringKind().gradeUnit,
                          showGrade: puzzle.scoringKind() != .vibes) { _ in }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THE ANSWER")
                .font(.heading)
                .foregroundStyle(Color.textPrimary)

            HStack(alignment: .top, spacing: 10) {
                pileColumn(title: String(localized: "KEEPS"), players: correctKeeps, fill: .successFill, on: .onSuccess)
                pileColumn(title: String(localized: "CUTS"), players: correctCuts, fill: .dangerFill, on: .onDanger)
            }
        }
    }

    /// One column (Keeps or Cuts) of compact, team-colored chips.
    private func pileColumn(title: String, players: [PlayerSeason], fill: Color, on: Color) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(on)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(fill)
            VStack(spacing: 0) {
                ForEach(Array(players.enumerated()), id: \.element.id) { i, player in
                    chip(player, correct: result.correctness[player.id] ?? false)
                    if i < players.count - 1 {
                        Rectangle().fill(Color.hairline).frame(height: Hairline.width)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 2))
    }

    private func chip(_ player: PlayerSeason, correct: Bool) -> some View {
        let team = TeamColors.palette(sport: puzzle.sport, abbr: player.teamAbbr)
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3).fill(team.primary).frame(width: 10, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.name)
                    .font(.custom(FontName.condBold, size: 13))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(CardLabel.dotJoined(player.teamAbbr.uppercased(),
                                         "'\(String(format: "%02d", player.seasonYear % 100))"))
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 2)
            if puzzle.scoringKind() != .vibes {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(player.gradeText)
                        .font(.hero(15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Color.textPrimary)
                    Text(puzzle.scoringKind().gradeUnit)
                        .font(.label11)
                        .foregroundStyle(Color.textMuted)
                }
            }
            Image(systemName: correct ? "checkmark" : "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(correct ? Color.successText : Color.dangerText)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.surface)
    }

    /// True top-4 (Keep answer) and bottom-4 (Cut answer), each ranked by grade.
    private var correctKeeps: [PlayerSeason] {
        let keep = puzzle.correctKeepIDs
        return puzzle.players.filter { keep.contains($0.id) }.sorted { $0.grade > $1.grade }
    }
    private var correctCuts: [PlayerSeason] {
        let keep = puzzle.correctKeepIDs
        return puzzle.players.filter { !keep.contains($0.id) }.sorted { $0.grade > $1.grade }
    }

    private var shareCardPreview: some View {
        let card = ShareCardView(puzzle: puzzle, placement: placement, result: result)
        return VStack(spacing: 12) {
            ShareLink(item: card.rendered(),
                      preview: SharePreview("My Playbook result", image: card.rendered())) {
                Label("SHARE RESULT", systemImage: "square.and.arrow.up").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            // ShareLink has no tap callback — a simultaneous gesture is the standard hook.
            .simultaneousGesture(TapGesture().onEnded {
                container.track(.shareTapped, ["surface": "result"])
            })
        }
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
