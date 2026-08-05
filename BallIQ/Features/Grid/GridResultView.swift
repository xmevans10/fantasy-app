import SwiftUI

struct GridResultView: View {
    let sport: Sport
    let score: Int
    let correctCount: Int
    var puzzle: GridPuzzle? = nil
    var solved: [Int: String] = [:]
    var rewards: RepositoryContainer.SessionRewards? = nil
    /// False for a re-rolled practice board. A practice board is not pinned to `(sport, day)`,
    /// so it cannot be challenged — the recipient would be sent to that day's *daily* board and
    /// unknowingly compared against a score set on a different grid.
    var isDaily: Bool = true
    /// Set when this run was itself opened from someone's challenge link — drives the
    /// head-to-head banner and the `challenge_completed` event.
    var challenge: ChallengeLink? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.requestReview) private var requestReview
    @State private var confetti = 0
    @State private var showLeaderboard = false
    /// cell index → (name → pct of that cell's correct picks). Empty until the crowd stats
    /// land (or forever, offline) — the recap simply shows no % line then.
    @State private var pickPct: [Int: [String: Int]] = [:]

    private var isPerfect: Bool { correctCount == 9 }

    /// The Immaculate-Grid-style emoji recap: 🟩 solved / ⬛ missed, row-major 3×3. Spoiler-free
    /// by construction — it shows the *shape* of a run without naming a single answer, which is
    /// exactly why this artifact travels and a screenshot of the board doesn't.
    static func emojiBoard(solved: [Int: String]) -> String {
        ShareMessage.emojiRow((0..<9).map { solved[$0] != nil }, perLine: 3)
    }

    /// The challenge this run represents — what a recipient would be playing against.
    static func challengeLink(sport: Sport, score: Int, solved: [Int: String],
                              date: Date = Date(), challenger: String? = nil) -> ChallengeLink {
        ChallengeLink(format: .grid, sport: sport, day: PuzzleStore.localDayString(date),
                      hits: solved.count, outOf: 9, score: score, challenger: challenger)
    }

    /// What actually lands in the share sheet. Pure so the exact text is locked by tests.
    ///
    /// The share IS the funnel (docs/MARKETING.md §1), so the message is built as a dare, not a
    /// report: headline first (so a stranger scrolling a group chat learns the sport, the game
    /// and the number in one line), then the spoiler-free board, then the score, then the link.
    /// `isDaily: false` drops the dare — see the property of the same name.
    static func shareText(sport: Sport, score: Int, solved: [Int: String], date: Date = Date(),
                          isDaily: Bool = true, challenger: String? = nil,
                          now: Date = Date()) -> String {
        let board = emojiBoard(solved: solved)
        let link = challengeLink(sport: sport, score: score, solved: solved,
                                 date: date, challenger: challenger)
        guard isDaily else {
            // A practice board has no shared identity to beat, so it gets the same picture and
            // the same link without a claim the recipient can't actually take up.
            return ["I went \(solved.count)/9 on a \(sport.displayName) Grid.", board,
                    link.scoreLine, link.storeURL.absoluteString].joined(separator: "\n")
        }
        return link.shareText(board: board, now: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    // Above the leaderboard on purpose: when you came here from a friend's dare,
                    // the one number you want is theirs, not this week's top 10.
                    if let challenge {
                        ChallengeResultBanner(challenge: challenge, hits: correctCount, score: score)
                            .heroReveal(1)
                    }
                    leaderboardEntry.heroReveal(challenge == nil ? 1 : 2)
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(3) }
                    if let puzzle { boardRecap(puzzle).heroReveal(4) }
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: isPerfect ? 90 : 40)
        .onAppear {
            if let challenge {
                container.track(.challengeCompleted, [
                    "format": ChallengeLink.Format.grid.rawValue,
                    "sport": sport.rawValue,
                    "outcome": String(describing: challenge.outcome(hits: correctCount, score: score)),
                ])
            }
            if isPerfect {
                confetti += 1
                // Rating ask at the pride moment, never after a miss (ReviewPrompter
                // self-throttles; the system sheet may still decline to appear).
                if ReviewPrompter.shouldAsk(immaculateGrid: true) { requestReview() }
            }
        }
        .task {
            let day = OverUnderRoundGenerator.dayString(Date())
            let stats = await container.gridGuessStats(day: day, sport: sport)
            var pct: [Int: [String: Int]] = [:]
            for row in stats where row.cellTotal > 0 {
                pct[row.cellIndex, default: [:]][row.guessName] = Int((Double(row.picks) / Double(row.cellTotal) * 100).rounded())
            }
            pickPct = pct
        }
        .sheet(isPresented: $showLeaderboard) {
            ArcadeLeaderboardView(game: .grid, sport: sport)
                .environmentObject(container)
        }
    }

    /// This week's board for Grid — always offered (even on an unranked replay), since a
    /// prior run today may already be the one ranked on it (mirrors the Daily Draft banner's
    /// "SEE TODAY'S BOARD" entry off `DraftSpinResultView`).
    private var leaderboardEntry: some View {
        ArcadeLeaderboardEntryRow(caption: "THIS WEEK'S TOP GRID RUNS") {
            showLeaderboard = true
        }
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

    /// A recap of all 9 cells (hit/miss + the matched player, where solved) — echoes
    /// `GridGameView.gridLayout`'s single flat `ForEach` shape (a `ForEach` nested inside
    /// another `ForEach` silently drops cells in `LazyVGrid`; see that file's comment).
    private func boardRecap(_ puzzle: GridPuzzle) -> some View {
        let cols = puzzle.cols.count
        let columns = [GridItem(.fixed(60))] + puzzle.cols.map { _ in GridItem(.flexible()) }
        let totalSlots = (puzzle.rows.count + 1) * (cols + 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("THE BOARD").font(.heading).foregroundStyle(Color.textPrimary)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<totalSlots, id: \.self) { slot in
                    let row = slot / (cols + 1)
                    let col = slot % (cols + 1)
                    if row == 0 {
                        if col == 0 {
                            Color.clear.frame(height: 36)
                        } else {
                            recapAxis(puzzle, axis: puzzle.cols[col - 1])
                        }
                    } else if col == 0 {
                        recapAxis(puzzle, axis: puzzle.rows[row - 1])
                    } else {
                        recapCell(row: row - 1, col: col - 1)
                    }
                }
            }
        }
    }

    /// Recap-sized twin of `GridGameView.axisCell` — a team axis keeps its crest chip, any other
    /// kind renders as a text label.
    @ViewBuilder
    private func recapAxis(_ puzzle: GridPuzzle, axis: GridPuzzle.GridAxis) -> some View {
        if axis.kind == .team {
            TeamAbbrChip(sport: puzzle.sport, abbr: axis.teamAbbr, league: axis.teamLeague,
                         fontSize: 12, minHeight: 36, showLogo: true,
                         displayText: axis.label)
        } else {
            Text(axis.label)
                .font(.custom(FontName.condBlack, size: 12))
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func recapCell(row: Int, col: Int) -> some View {
        let index = row * 3 + col
        return VStack(spacing: 2) {
            if let name = solved[index] {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.successText)
                Text(name).font(.label11).foregroundStyle(Color.textPrimary).lineLimit(2).minimumScaleFactor(0.6)
                if let pct = pickPct[index]?[name] {
                    Text("\(pct)% picked").font(.label11).foregroundStyle(Color.textMuted)
                }
            } else {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.dangerText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(4)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The card previewed in the share sheet next to `shareText`. Same spoiler-free shape as
    /// `emojiBoard` — never renders `solved`'s player names, since a screenshot of the real
    /// board is exactly the artifact this format exists to avoid producing.
    private var shareCard: GridShareCardView {
        GridShareCardView(sport: sport, score: score, correctCount: correctCount, solved: solved)
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            HStack(spacing: 12) {
                ShareLink(item: Self.shareText(sport: sport, score: score, solved: solved,
                                               isDaily: isDaily,
                                               challenger: container.identity.username),
                          preview: SharePreview(isDaily ? "Grid challenge" : "Grid result",
                                                image: shareCard.rendered())) {
                    Label(isDaily ? "CHALLENGE A FRIEND" : "SHARE", systemImage: "square.and.arrow.up")
                        .font(.heading).foregroundStyle(Color.accentText)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                // ShareLink has no tap callback — a simultaneous gesture is the standard hook.
                // Until now the Grid — the format whose share artifact is the entire growth
                // thesis — logged nothing here at all, so none of its shares are in the 6.
                .simultaneousGesture(TapGesture().onEnded {
                    container.track(.shareTapped, AnalyticsEvent.shareProperties(
                        surface: "grid_result",
                        format: ChallengeLink.Format.grid.rawValue,
                        artifact: .challengeText,
                        extra: ["sport": sport.rawValue, "hits": String(correctCount),
                                "is_daily": String(isDaily)]))
                })
                Button(action: onDone) {
                    Text("DONE").font(.heading).foregroundStyle(Color.accentText)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.surface)
        }
    }
}

/// The shareable result image for a Grid run — the emoji-only recap `emojiBoard`/`shareText`
/// already send as plain text, now as a rendered card. Deliberately shows the same spoiler-free
/// 🟩/⬛ shape and NOT `solved`'s player names: a screenshot of the real board is the one
/// artifact this format is designed to avoid producing.
struct GridShareCardView: View {
    let sport: Sport
    let score: Int
    let correctCount: Int
    var solved: [Int: String] = [:]

    private var isPerfect: Bool { correctCount == 9 }

    private let columns = [GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)]

    var body: some View {
        ShareCardFrame {
            ShareCardHeaderBand(rare: isPerfect) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Wordmark(size: 20)
                        Spacer()
                        Text("GRID")
                            .font(.custom(FontName.condBlack, size: 14))
                            .foregroundStyle((isPerfect ? Color.onVolt : Color.onAccent).opacity(0.85))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(score)")
                            .font(.hero(40))
                            .foregroundStyle(isPerfect ? Color.onVolt : Color.onAccent)
                        Text("\(correctCount) OF 9 CORRECT")
                            .font(.custom(FontName.condBlack, size: 15))
                            .foregroundStyle((isPerfect ? Color.onVolt : Color.onAccent).opacity(0.85))
                    }
                }
            }

            // The spoiler-free board: same solved[i] != nil boolean logic as `emojiBoard`,
            // rendered as colored squares instead of the text glyphs (a rendered image needs
            // its own layout, but never a different source of truth for which cells hit).
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(solved[i] != nil ? Color.successFill : Color.surfaceMuted)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.borderInk, lineWidth: 1.5)
                        )
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(16)
            .background(Color.surface1)

            ShareCardFooter()
        }
    }
}

extension GridShareCardView {
    @MainActor
    func rendered(scale: CGFloat = 3) -> Image { renderedForShare(scale: scale) }
}
