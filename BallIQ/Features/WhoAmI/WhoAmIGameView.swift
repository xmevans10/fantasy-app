import SwiftUI

struct WhoAmIGameView: View {
    let puzzle: WhoAmIPuzzle
    /// Daily play is ranked; community puzzles pass `ranked: false` (XP only, no rating).
    var ranked: Bool = true
    /// Set for community puzzles so a play is logged (powers the Popular sort).
    var communityID: String? = nil

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var revealedCount = 1
    @State private var guess = ""
    @State private var wrongGuesses = 0
    @State private var wrongShake = false
    @State private var result: WhoAmIScoring.Result?
    @State private var rewards: RepositoryContainer.SessionRewards?
    @FocusState private var fieldFocused: Bool
    @State private var showReportDialog = false
    @State private var showReportSent = false
    @State private var didLogStart = false
    @State private var startedAt: Date?

    private var allRevealed: Bool { revealedCount >= puzzle.clues.count }
    /// Points on the table right now — the tier-scaled clue value less the wrong-guess
    /// penalties already taken, so the header always matches what a solve would actually pay.
    private var currentValue: Int {
        max(0, WhoAmIScoring.value(cluesUsed: revealedCount, difficulty: puzzle.difficulty)
            + wrongGuesses * WhoAmIScoring.wrongPenalty)
    }
    private var nextCueCost: Int {
        guard !allRevealed else { return 0 }
        return WhoAmIScoring.value(cluesUsed: revealedCount, difficulty: puzzle.difficulty)
            - WhoAmIScoring.value(cluesUsed: revealedCount + 1, difficulty: puzzle.difficulty)
    }

    var body: some View {
        Group {
            if let result {
                WhoAmIResultView(puzzle: puzzle, result: result, rewards: rewards) { dismiss() }
            } else {
                playBoard
            }
        }
        .background(Color.appBackground)
        .onAppear {
            if !didLogStart {
                didLogStart = true
                startedAt = Date()
                container.track(.gameStarted, ["format": "whoami", "ranked": "\(ranked)",
                                               "difficulty": puzzle.difficulty?.rawValue ?? "unrated",
                                               "community": "\(communityID != nil)"])
            }
            if DebugLaunch.autoSubmitResult { autoSolveForScreenshot() }
        }
        .reportReasonDialog(isPresented: $showReportDialog) { reason in report(reason: reason) }
        .alert("Report sent", isPresented: $showReportSent) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thanks — we'll take a look.")
        }
    }

    /// Best-effort (matches `reportCommunity`'s own `try?` fire-and-forget).
    private func report(reason: String) {
        guard let communityID else { return }
        Task {
            await container.reportCommunity(id: communityID, reason: reason)
            Haptics.success()
            showReportSent = true
        }
    }

    private var playBoard: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(puzzle.clues.prefix(revealedCount)) { clue in
                        clueRow(clue)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(16)
            }
            guessBar
        }
        .background(Color.appBackground)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.textMuted)
                }
                .accessibilityLabel("Close")
                Spacer()
                difficultyChip
                Text(puzzle.sport.displayName)
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                if communityID != nil {
                    Button { showReportDialog = true } label: {
                        Image(systemName: "flag")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.textMuted)
                    }
                    .accessibilityLabel("Report this puzzle")
                    .padding(.leading, 12)
                }
            }
            VStack(spacing: 4) {
                Text("Who am I?")
                    .font(.label12)
                    .foregroundStyle(Color.accentText)
                Text("Worth \(currentValue) pts")
                    .font(.heading)
                    .foregroundStyle(Color.textPrimary)
                Text("Clue \(revealedCount) of \(puzzle.clues.count)")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(16)
        .background(Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
        }
    }

    /// Tier chip in the play header. Carries the multiplier as well as the tier name — "HARD"
    /// alone tells a player the puzzle is worse for them, which is only half the trade.
    /// Absent for unrated puzzles (community-authored, or content minted before tiers existed),
    /// which is why this is a `@ViewBuilder` returning nothing rather than a neutral chip.
    @ViewBuilder
    private var difficultyChip: some View {
        if let difficulty = puzzle.difficulty {
            HStack(spacing: 4) {
                Image(systemName: difficulty.symbol).font(.system(size: 9, weight: .bold))
                Text(difficulty.badgeLabel).font(.label11)
                if difficulty != .easy {
                    Text("· \(difficulty.multiplierLabel)").font(.label11).opacity(0.8)
                }
            }
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(difficulty.tintText)
            .background(difficulty.tintBg)
            .clipShape(Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(difficulty == .easy
                ? String(localized: "Difficulty: easy")
                : String(localized: "Difficulty: \(difficulty.badgeLabel.lowercased()), \(difficulty.multiplierLabel)"))
        }
    }

    private func clueRow(_ clue: WhoAmIPuzzle.Clue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(clue.order)")
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(Color.accentText)
                .frame(width: 26, height: 26)
                .background(Color.accentBg)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(clue.displayLabel)
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                Text(clue.text)
                    .font(.body14)
                    .foregroundStyle(Color.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private var guessBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Name the player", text: $guess)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .onSubmit(submitGuess)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Color.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .offset(x: wrongShake ? -8 : 0)

                    Button(action: submitGuess) {
                        Text("GUESS")
                            .font(.heading)
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.accentFill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(PrimePressStyle())
                    .accessibilityHint("Submits the name you entered")
                }

                HStack {
                    if wrongGuesses > 0 {
                        Text("\(wrongGuesses) wrong · −\(wrongGuesses * 100) pts")
                            .font(.label12)
                            .foregroundStyle(Color.dangerText)
                    }
                    Spacer()
                    if allRevealed {
                        Button("Give up", action: giveUp)
                            .font(.body14)
                            .foregroundStyle(Color.textMuted)
                    } else {
                        Button(action: nextClue) {
                            Text("Next clue · −\(nextCueCost) pts")
                                .font(.bodyStrong)
                                .foregroundStyle(Color.accentText)
                        }
                        .accessibilityLabel("Reveal next clue")
                        .accessibilityHint("Costs \(nextCueCost) points")
                    }
                }
            }
            .padding(16)
            .background(Color.surface)
        }
    }

    // MARK: - Actions

    private func submitGuess() {
        let trimmed = guess.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if AnswerMatcher.matches(trimmed, answer: puzzle.answer) {
            finish(solved: true)
        } else {
            wrongGuesses += 1
            guess = ""
            Haptics.reject()
            withAnimation(Motion.snap) { wrongShake = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(Motion.snap) { wrongShake = false }
            }
        }
    }

    private func nextClue() {
        guard !allRevealed else { return }
        Haptics.tap()
        withAnimation(Motion.easeOut) { revealedCount += 1 }
    }

    private func giveUp() { finish(solved: false) }

    private func finish(solved: Bool) {
        fieldFocused = false
        let r = WhoAmIScoring.score(cluesUsed: revealedCount, wrongGuesses: wrongGuesses,
                                    solved: solved, difficulty: puzzle.difficulty)
        if solved { Haptics.success() }
        let perfect = solved && revealedCount == 1 && wrongGuesses == 0
        var details = GameResultDetails()
        details.cluesUsed = revealedCount
        details.wrongGuesses = wrongGuesses
        details.solved = solved
        details.answerName = puzzle.answer.canonical
        let detail = RepositoryContainer.SessionDetail(
            mode: communityID != nil ? .community : .daily,
            score: r.total, maxScore: WhoAmIScoring.maxScore(difficulty: puzzle.difficulty),
            correct: solved ? 1 : 0, attempted: 1,
            startedAt: startedAt, details: details)
        Task { @MainActor in
            let rw = await container.complete(format: .whoAmI, sport: puzzle.sport,
                                              performance: r.performance, perfect: perfect,
                                              puzzleID: puzzle.id, ranked: ranked, detail: detail)
            rewards = rw
            if let communityID { await container.recordCommunityPlay(id: communityID) }
            withAnimation(Motion.easeOut) { result = r }
        }
    }

    /// Debug-only: reveal a few clues then solve, to screenshot the result.
    private func autoSolveForScreenshot() {
        revealedCount = 3
        finish(solved: true)
    }
}
