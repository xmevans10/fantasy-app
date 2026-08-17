import SwiftUI

struct Keep4ResultView: View {
    let puzzle: Keep4Puzzle
    let placement: [String: Pile]
    let result: Keep4Scoring.Result
    var rewards: RepositoryContainer.SessionRewards? = nil
    /// Whether this was today's daily board, and therefore something a friend can be dared onto.
    ///
    /// Defaults to **false**, which is the safe answer: this same view also serves the archive,
    /// community puzzles, Versus and deep-linked plays, and a share claiming "today's NFL Keep 4"
    /// after an archive run from 2019 would send a challenge naming a board the recipient will
    /// never be given. `Keep4GameView` passes `ranked`, which is already exactly this distinction
    /// at every call site (Home's daily, Browse's daily-from-hub and Onboarding's first puzzle
    /// are ranked; archive/community/Versus/deep-link are not).
    var isDaily: Bool = false
    /// Set when this run came from someone's challenge link — see `ChallengeResultBanner`.
    var challenge: ChallengeLink? = nil
    /// Set when this run was a **bot ladder** duel — the finished head-to-head against the rung's
    /// bot. Distinct from `challenge`, which is a link someone sent; both render through
    /// `ChallengeResultBanner`, and exactly one of them is ever set.
    var duelVerdict: DuelVerdict? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.requestReview) private var requestReview
    @Environment(\.ladderRematch) private var ladderRematch
    @State private var confetti = 0
    @State private var rematching = false

    private var heroFill: Color { result.isPerfect ? .voltFill : .accentFill }
    private var heroInk: Color { result.isPerfect ? .onVolt : .onAccent }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    if let challenge {
                        ChallengeResultBanner(challenge: challenge,
                                              hits: result.correctCount,
                                              score: result.total)
                            .heroReveal(1)
                    } else if let duelVerdict {
                        ChallengeResultBanner(verdict: duelVerdict).heroReveal(1)
                    }
                    if let top = topSeason { foilCard(top).heroReveal(2) }
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(3) }
                    breakdown.heroReveal(4)
                    shareCardPreview.heroReveal(5)
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: result.isPerfect ? 90 : 40)
        .onAppear {
            if let challenge {
                container.track(.challengeCompleted, [
                    "format": ChallengeLink.Format.keep4.rawValue,
                    "sport": puzzle.sport.rawValue,
                    "outcome": String(describing: challenge.outcome(hits: result.correctCount,
                                                                   score: result.total)),
                ])
            }
            let gained = (rewards?.ratingChange.delta ?? 0) > 0
            if result.isPerfect || gained { confetti += 1 }
            // Rating ask when the daily just extended a week-plus streak — a pride moment,
            // and self-throttled (see ReviewPrompter).
            if ReviewPrompter.shouldAsk(streak: rewards?.newStreak ?? 0) { requestReview() }
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

    /// 🟩 correct / ⬛ wrong, in board order, four to a line. The Grid's emoji-recap idea applied
    /// to Keep 4 — and the reason the rendered card is no longer the thing that gets sent:
    /// `ShareCardView` lists all eight players with KEEP/CUT and a tick, which is the complete
    /// answer key. Posting it to a group chat solves the puzzle for everyone who reads it, so
    /// the one artifact most likely to spread was also the one guaranteed to burn the board.
    static func emojiStrip(puzzle: Keep4Puzzle, result: Keep4Scoring.Result) -> String {
        ShareMessage.emojiRow(puzzle.players.map { result.correctness[$0.id] ?? false }, perLine: 4)
    }

    /// What lands in the share sheet: headline, spoiler-free strip, score, link. Pure, so the
    /// exact text is locked by tests — same contract as `GridResultView.shareText`.
    static func shareText(puzzle: Keep4Puzzle, result: Keep4Scoring.Result, date: Date = Date(),
                          isDaily: Bool = true, challenger: String? = nil,
                          now: Date = Date()) -> String {
        let board = emojiStrip(puzzle: puzzle, result: result)
        let link = ChallengeLink(format: .keep4, sport: puzzle.sport,
                                 day: PuzzleStore.localDayString(date),
                                 hits: result.correctCount, outOf: puzzle.players.count,
                                 score: result.total, challenger: challenger)
        guard isDaily else {
            // An archive or community board has no shared identity, so the message brags without
            // daring — same rule as a re-rolled practice Grid.
            return ShareMessage.compose(
                headline: "I went \(result.correctCount)/\(puzzle.players.count) on a \(puzzle.sport.displayName) Keep 4.",
                board: board, detail: link.scoreLine, campaign: link.campaignToken)
        }
        return link.shareText(board: board, now: now)
    }

    private var shareCardPreview: some View {
        // The card still fronts the share sheet as its preview thumbnail — `SharePreview` is
        // sheet chrome, not payload, so it looks as good as it did without travelling with the
        // message and giving the answers away.
        let card = ShareCardView(puzzle: puzzle, placement: placement, result: result)
        return VStack(spacing: 12) {
            ShareLink(item: Self.shareText(puzzle: puzzle, result: result, isDaily: isDaily,
                                           challenger: container.identity.username),
                      preview: SharePreview("My Playbook result", image: card.rendered())) {
                Label(isDaily ? "CHALLENGE A FRIEND" : "SHARE RESULT",
                      systemImage: "square.and.arrow.up").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            // ShareLink has no tap callback — a simultaneous gesture is the standard hook.
            .simultaneousGesture(TapGesture().onEnded {
                container.track(.shareTapped, AnalyticsEvent.shareProperties(
                    surface: "keep4_result",
                    format: ChallengeLink.Format.keep4.rawValue,
                    artifact: .challengeText,
                    extra: ["sport": puzzle.sport.rawValue,
                            "hits": String(result.correctCount)]))
            })
        }
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            HStack(spacing: 12) {
                Button(action: onDone) {
                    Text("DONE")
                        .font(.heading)
                        .foregroundStyle(Color.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                if let ladderRematch {
                    RematchButton(rematching: $rematching, action: ladderRematch)
                }
            }
            .padding(16)
            .background(Color.surface)
        }
    }
}
