import SwiftUI

/// The Grid (M5 Phase E, Pro-only): a 3x3 team x decade board, 9 total guesses (one attempt
/// per cell — decisions are final, same posture as Keep4). Ranked through the normal
/// `complete(...)` pipeline; content comes only from `PuzzleRepository.gridPuzzle` (server-
/// generated, no offline bundle — see that protocol's doc comment).
struct GridGameView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var puzzle: GridPuzzle?
    @State private var loading = true
    /// Index (row*3+col) -> the matched valid-answer name, once correctly guessed.
    @State private var solved: [Int: String] = [:]
    @State private var wrong: Set<Int> = []
    @State private var activeCell: Int?
    @State private var guessText = ""
    @State private var result: (score: Int, correctCount: Int)?
    @State private var rewards: RepositoryContainer.SessionRewards?

    @State private var showingSetup = true
    @State private var sport: Sport = .nfl
    private var attemptedCount: Int { solved.count + wrong.count }

    var body: some View {
        Group {
            if let result {
                GridResultView(sport: sport, score: result.score, correctCount: result.correctCount,
                               puzzle: puzzle, solved: solved,
                               rewards: rewards, onDone: { dismiss() })
            } else if showingSetup {
                GameSetupScreen(formatName: "The Grid", title: "Pick your sport",
                                startLabel: "Open the grid", sport: $sport,
                                onStart: { Task { await load() } },
                                onClose: { dismiss() }) { EmptyView() }
            } else if loading {
                ProgressView().tint(Color.accentText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let puzzle {
                board(puzzle)
            } else {
                EmptyStateView(symbol: "square.grid.3x3", title: "No Grid today",
                              message: "Check back tomorrow for a new Grid.",
                              actionTitle: "Close", action: { dismiss() })
            }
        }
        .background(Color.appBackground)
        .task {
            sport = container.sportFilter.sport ?? .nfl
            // Screenshot flows target the board/result — skip the setup screen.
            if DebugLaunch.autoOpenGrid { await load() }
        }
        .alert("Name that player", isPresented: Binding(get: { activeCell != nil }, set: { if !$0 { activeCell = nil } })) {
            TextField("Player name", text: $guessText)
                .textInputAutocapitalization(.words)
            Button("Guess") { submitGuess() }
            Button("Cancel", role: .cancel) { activeCell = nil; guessText = "" }
        } message: {
            if let activeCell, let puzzle {
                Text(cellPrompt(puzzle, index: activeCell))
            }
        }
    }

    private func load() async {
        showingSetup = false
        // The setup screen's pick is already one concrete sport — never `.all`, which
        // carries no sport and would fetch every sport's grid row and silently pick
        // whichever sorts first (a real bug the old filter-derived flow hit).
        let resolvedFilter = SportFilter(rawValue: sport.rawValue) ?? .nfl
        puzzle = await container.puzzles.gridPuzzle(for: resolvedFilter, date: Date())
        container.track(.gameStarted, ["format": "grid", "sport": sport.rawValue])
        loading = false
        if DebugLaunch.autoSubmitGrid, let puzzle { autoSolveForScreenshot(puzzle) }
    }

    // MARK: - Board

    private func board(_ puzzle: GridPuzzle) -> some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            gridLayout(puzzle).padding(16)
            Spacer(minLength: 0)
            footer
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("Close")
                Spacer()
                Text("\(attemptedCount) OF 9 GUESSED").font(.label12).foregroundStyle(Color.textMuted)
            }
            Text("THE GRID").font(.label12).foregroundStyle(Color.proText)
            Text("\(sport.displayName) legends").font(.title).foregroundStyle(Color.textPrimary)
        }
        .padding(16)
        .background(Color.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: Hairline.width) }
    }

    /// A single flat `ForEach` over every board slot (header row + label column + answer
    /// cells), rather than nesting a `ForEach` inside another `ForEach` — `LazyVGrid` doesn't
    /// reliably flatten that nested shape, which silently dropped all 9 answer cells (they
    /// never appeared, even as zero-content placeholders — confirmed by temporarily forcing
    /// their background to a debug color and seeing nothing render).
    private func gridLayout(_ puzzle: GridPuzzle) -> some View {
        let cols = puzzle.colDecades.count
        let columns = [GridItem(.fixed(72))] + puzzle.colDecades.map { _ in GridItem(.flexible()) }
        let totalSlots = (puzzle.rowTeams.count + 1) * (cols + 1)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<totalSlots, id: \.self) { slot in
                let row = slot / (cols + 1)
                let col = slot % (cols + 1)
                if row == 0 {
                    if col == 0 {
                        Color.clear.frame(height: 44)
                    } else {
                        labelCell("\(puzzle.colDecades[col - 1])s")
                    }
                } else if col == 0 {
                    labelCell(puzzle.rowTeams[row - 1].uppercased())
                } else {
                    answerCell(puzzle, row: row - 1, col: col - 1)
                }
            }
        }
    }

    private func labelCell(_ text: String) -> some View {
        Text(text)
            .font(.custom(FontName.condBlack, size: 14))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func answerCell(_ puzzle: GridPuzzle, row: Int, col: Int) -> some View {
        let index = row * 3 + col
        let cell = puzzle.cell(row: row, col: col)
        return Button {
            guard solved[index] == nil, !wrong.contains(index) else { return }
            activeCell = index
        } label: {
            VStack(spacing: 2) {
                if let name = solved[index] {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.successText)
                    Text(name).font(.label11).foregroundStyle(Color.textPrimary).lineLimit(2).minimumScaleFactor(0.6)
                } else if wrong.contains(index) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.dangerText)
                } else {
                    starRating(cell.rarityStars)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(4)
        }
        .buttonStyle(.plain)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.borderInk, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(solved[index] != nil || wrong.contains(index))
        .accessibilityLabel(accessibilityLabel(cell: cell, index: index))
    }

    private func starRating(_ stars: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<stars, id: \.self) { _ in
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Color.warningFill)
            }
        }
    }

    private func accessibilityLabel(cell: GridPuzzle.GridCell, index: Int) -> String {
        if let name = solved[index] { return "Solved: \(name)" }
        if wrong.contains(index) { return "Missed" }
        return "Empty cell, rarity \(cell.rarityStars) of 5 stars"
    }

    private var footer: some View {
        Text("Tap a cell and name a player who fits both the team and the era. One guess per cell.")
            .font(.label11).foregroundStyle(Color.textMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 16)
    }

    private func cellPrompt(_ puzzle: GridPuzzle, index: Int) -> String {
        let row = index / 3, col = index % 3
        return "\(puzzle.rowTeams[row].uppercased()) in the \(puzzle.colDecades[col])s"
    }

    // MARK: - Logic

    private func submitGuess() {
        guard let index = activeCell, let puzzle else { return }
        let row = index / 3, col = index % 3
        let guess = guessText
        guessText = ""
        activeCell = nil

        if puzzle.isCorrect(row: row, col: col, guess: guess) {
            let matched = puzzle.cell(row: row, col: col).validAnswerNames.first { name in
                AnswerMatcher.matches(guess, answer: .init(canonical: name, aliases: []))
            } ?? guess
            solved[index] = matched
            Haptics.success()
        } else {
            wrong.insert(index)
            Haptics.reject()
        }

        if attemptedCount >= 9 { finish(puzzle) }
    }

    private func finish(_ puzzle: GridPuzzle) {
        let totalStars = solved.keys.reduce(0) { sum, index in
            sum + puzzle.cell(row: index / 3, col: index % 3).rarityStars
        }
        let score = solved.count * 100 + totalStars * 20
        let performance = Double(solved.count) / 9.0
        let dailyID = "grid-\(sport.rawValue)-\(OverUnderRoundGenerator.dayString(Date()))"
        let ranked = !container.hasCompletedToday(puzzleID: dailyID)
        Task {
            rewards = await container.complete(format: .grid, sport: sport, performance: performance,
                                               perfect: solved.count == 9, puzzleID: dailyID, ranked: ranked)
            withAnimation(Motion.snap) { result = (score, solved.count) }
        }
    }

    /// `-screenshotGridResult`: simctl can't type into the guess field, so auto-answer every
    /// cell with its first valid answer.
    private func autoSolveForScreenshot(_ puzzle: GridPuzzle) {
        for index in 0..<9 {
            let row = index / 3, col = index % 3
            if let first = puzzle.cell(row: row, col: col).validAnswerNames.first {
                solved[index] = first
            }
        }
        finish(puzzle)
    }
}
