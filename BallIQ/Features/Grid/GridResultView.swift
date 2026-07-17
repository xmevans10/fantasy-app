import SwiftUI

struct GridResultView: View {
    let sport: Sport
    let score: Int
    let correctCount: Int
    var puzzle: GridPuzzle? = nil
    var solved: [Int: String] = [:]
    var rewards: RepositoryContainer.SessionRewards? = nil
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer
    @State private var confetti = 0
    @State private var showLeaderboard = false
    /// cell index → (name → pct of that cell's correct picks). Empty until the crowd stats
    /// land (or forever, offline) — the recap simply shows no % line then.
    @State private var pickPct: [Int: [String: Int]] = [:]

    private var isPerfect: Bool { correctCount == 9 }

    /// The Immaculate-Grid-style emoji recap: 🟩 solved / ⬛ missed, row-major 3×3. Pure so
    /// the exact share text is locked by tests.
    static func shareText(sport: Sport, score: Int, solved: [Int: String], date: Date = Date()) -> String {
        let rows = (0..<3).map { row in
            (0..<3).map { col in solved[row * 3 + col] != nil ? "🟩" : "⬛" }.joined()
        }.joined(separator: "\n")
        let day = OverUnderRoundGenerator.dayString(date)
        return "Playbook Grid — \(sport.displayName) \(day)\n\(rows)\nScore \(score)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    scoreHeader.heroReveal(0)
                    leaderboardEntry.heroReveal(1)
                    if let rewards { RewardsRow(rewards: rewards).heroReveal(2) }
                    if let puzzle { boardRecap(puzzle).heroReveal(3) }
                }
                .padding(16)
            }
            doneBar
        }
        .background(Color.appBackground)
        .celebrate(on: $confetti, intensity: isPerfect ? 90 : 40)
        .onAppear { if isPerfect { confetti += 1 } }
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
        let cols = puzzle.colDecades.count
        let columns = [GridItem(.fixed(60))] + puzzle.colDecades.map { _ in GridItem(.flexible()) }
        let totalSlots = (puzzle.rowTeams.count + 1) * (cols + 1)
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
                            recapLabel("\(puzzle.colDecades[col - 1])s")
                        }
                    } else if col == 0 {
                        TeamAbbrChip(sport: puzzle.sport, abbr: puzzle.rowTeams[row - 1], fontSize: 12, minHeight: 36)
                    } else {
                        recapCell(row: row - 1, col: col - 1)
                    }
                }
            }
        }
    }

    private func recapLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom(FontName.condBlack, size: 12))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    private var doneBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            HStack(spacing: 12) {
                ShareLink(item: Self.shareText(sport: sport, score: score, solved: solved)) {
                    Label("SHARE", systemImage: "square.and.arrow.up")
                        .font(.heading).foregroundStyle(Color.accentText)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.plain)
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
