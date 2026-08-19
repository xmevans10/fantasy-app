import SwiftUI

/// Journeyman: the whole career path on screen, five guesses to name the player.
///
/// Built to the same grammar as `WhoAmIGameView` — same header, same guess bar, the same
/// points-decay language — because they are the same bet with a different board. The one
/// difference is what spends the points: Who Am I? sells you information, Journeyman gives you
/// all of it up front and charges you for being wrong.
struct JourneymanGameView: View {
    let puzzle: JourneymanPuzzle
    /// Daily play is ranked; archive runs pass `ranked: false` (XP only, no rating).
    var ranked: Bool = true
    /// Set when opened from a `balliq://challenge` link — see `WhoAmIGameView.challenge`.
    var challenge: ChallengeLink? = nil
    /// Set when this board is being played as a timed Versus duel. `duel` wins over `challenge`
    /// for the same reason it does in `WhoAmIGameView`.
    var duel: DuelSession? = nil

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var guess = ""
    /// Wrong guesses so far. The *next* guess is number `wrongGuesses + 1`.
    @State private var wrongGuesses = 0
    @State private var wrongShake = false
    @State private var result: JourneymanScoring.Result?
    @State private var rewards: RepositoryContainer.SessionRewards?
    /// Sport-wide player names powering the guess autocomplete. Empty offline, where the field
    /// degrades to free text — exactly what The Grid does.
    @State private var nameIndex: [String] = []
    @State private var normalizedNames: [(display: String, norm: String)] = []
    @FocusState private var fieldFocused: Bool
    @State private var didLogStart = false
    @State private var startedAt: Date?

    /// Which guess the player is about to make, 1-based.
    private var currentGuess: Int { wrongGuesses + 1 }
    private var guessesLeft: Int { JourneymanScoring.maxGuesses - wrongGuesses }
    /// What naming the player right now would pay.
    private var currentValue: Int {
        JourneymanScoring.value(guess: currentGuess, difficulty: puzzle.difficulty)
    }
    /// What being wrong would cost. Zero on the last guess, where a miss ends the run instead.
    private var nextGuessCost: Int {
        JourneymanScoring.nextGuessCost(guess: currentGuess, difficulty: puzzle.difficulty)
    }

    private var effectiveChallenge: ChallengeLink? { duel == nil ? challenge : nil }
    private var isDaily: Bool { duel == nil && (ranked || challenge != nil) }

    private var trimmedGuess: String { guess.trimmingCharacters(in: .whitespaces) }
    private var suggestions: [String] {
        GridGuessSheet.rank(query: trimmedGuess, normalized: normalizedNames)
    }

    var body: some View {
        Group {
            if let result {
                JourneymanResultView(puzzle: puzzle, result: result, rewards: rewards,
                                     isDaily: isDaily, challenge: effectiveChallenge,
                                     duelVerdict: duel?.ladder?
                                        .verdict(myHits: ChallengeLink.journeymanHits(result))) { dismiss() }
            } else {
                playBoard
            }
        }
        .background(Color.appBackground)
        .task {
            if nameIndex.isEmpty {
                nameIndex = await container.puzzles.playerNameIndex(for: puzzle.sport)
                normalizedNames = nameIndex.map { ($0, AnswerMatcher.normalize($0)) }
            }
        }
        .onAppear {
            if !didLogStart {
                didLogStart = true
                startedAt = Date()
                container.track(.gameStarted, ["format": "journeyman", "ranked": "\(ranked)",
                                               "difficulty": puzzle.difficulty?.rawValue ?? "unrated",
                                               "clubs": "\(puzzle.stints.count)",
                                               "duel": "\(duel != nil)"])
            }
            if DebugLaunch.autoSubmitResult { autoSolveForScreenshot() }
        }
    }

    private var playBoard: some View {
        VStack(spacing: 0) {
            if let duel {
                DuelTimerBar(session: duel, playerScore: wrongGuesses) {
                    if result == nil { finish(solved: false) }
                }
            }
            header
            // Centred rather than top-aligned: a two- or three-club board is short, and pinned to
            // the top it left two thirds of the screen empty under it. The `minHeight` makes the
            // scroll content fill the viewport so the path sits in the middle of the space it
            // has, while an eight-club board still scrolls normally.
            GeometryReader { proxy in
                ScrollView {
                    CareerPathTimeline(sport: puzzle.sport, stints: puzzle.stints,
                                       truncated: puzzle.truncated ?? false)
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height,
                               alignment: .center)
                }
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
            }
            VStack(spacing: 4) {
                Text("Journeyman")
                    .font(.label12)
                    .foregroundStyle(Color.accentText)
                Text("Worth \(currentValue) pts")
                    .font(.heading)
                    .foregroundStyle(Color.textPrimary)
                Text(guessesLeft == 1 ? "1 guess left" : "\(guessesLeft) guesses left")
                    .font(.label11)
                    .foregroundStyle(guessesLeft == 1 ? Color.dangerText : Color.textMuted)
            }
        }
        .padding(16)
        .background(Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
        }
    }

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

    // MARK: - Guessing

    private var guessBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: Hairline.width)
            suggestionStrip
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Name the player", text: $guess)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .onSubmit { submit(trimmedGuess) }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Color.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .offset(x: wrongShake ? -8 : 0)

                    Button { submit(trimmedGuess) } label: {
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
                    // The price of being wrong, stated before the guess rather than after it —
                    // it's the only cost in this format, so hiding it until it's charged would
                    // make the score move for reasons the player never saw coming.
                    Text(guessesLeft > 1
                         ? "A wrong guess costs \(nextGuessCost) pts"
                         : "Last guess")
                        .font(.label12)
                        .foregroundStyle(guessesLeft > 1 ? Color.textMuted : Color.dangerText)
                    Spacer()
                    Button("Give up", action: giveUp)
                        .font(.body14)
                        .foregroundStyle(Color.textMuted)
                }
            }
            .padding(16)
            .background(Color.surface)
        }
    }

    /// The autocomplete, inline above the field rather than in a sheet. Same ranker The Grid
    /// uses (`GridGuessSheet.rank`), and sport-wide for the same reason: a list narrowed to
    /// players who fit this board would be the answer.
    @ViewBuilder
    private var suggestionStrip: some View {
        let hits = suggestions
        if !hits.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(hits, id: \.self) { name in
                        Button { submit(name) } label: {
                            Text(name)
                                .font(.body14)
                                .foregroundStyle(Color.textPrimary)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.surfaceMuted)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 52)
            .background(Color.surface)
        }
    }

    private func submit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, result == nil else { return }
        if AnswerMatcher.matches(trimmed, answer: puzzle.answer) {
            finish(solved: true)
            return
        }
        wrongGuesses += 1
        guess = ""
        Haptics.reject()
        withAnimation(Motion.snap) { wrongShake = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(Motion.snap) { wrongShake = false }
        }
        // Out of guesses ends the run — the five-guess limit is what makes an early solve worth
        // anything, so it has to actually bite.
        if wrongGuesses >= JourneymanScoring.maxGuesses { finish(solved: false) }
    }

    private func giveUp() { finish(solved: false) }

    private func finish(solved: Bool) {
        // Idempotent: the duel timer and a landing guess can both try to finish one run.
        guard result == nil else { return }
        fieldFocused = false
        let r = JourneymanScoring.score(guessesUsed: solved ? currentGuess : wrongGuesses,
                                        solved: solved, difficulty: puzzle.difficulty)
        if solved { Haptics.success() }
        let perfect = solved && wrongGuesses == 0
        var details = GameResultDetails()
        details.cluesUsed = r.guessesUsed
        details.wrongGuesses = r.wrongGuesses
        details.solved = solved
        details.answerName = puzzle.answer.canonical
        details.opponentUserID = duel?.opponentUserID
        let mode: PlayMode = duel != nil ? .versus : (ranked ? .daily : .archive)
        let detail = RepositoryContainer.SessionDetail(
            mode: mode,
            score: r.total,
            maxScore: JourneymanScoring.maxScore(difficulty: puzzle.difficulty),
            correct: solved ? 1 : 0, attempted: 1,
            startedAt: startedAt, details: details)
        Task { @MainActor in
            if let duel {
                await container.logSession(format: .journeyman, sport: puzzle.sport,
                                           performance: r.performance, perfect: perfect,
                                           puzzleID: puzzle.id, detail: detail)
                await container.submitDuelResult(duel, performance: r.performance,
                                                 elapsed: Date().timeIntervalSince(startedAt ?? Date()))
            } else {
                rewards = await container.complete(format: .journeyman, sport: puzzle.sport,
                                                   performance: r.performance, perfect: perfect,
                                                   puzzleID: puzzle.id, ranked: ranked, detail: detail)
            }
            withAnimation(Motion.easeOut) { result = r }
        }
    }

    /// Debug-only: burn a guess, then solve, to screenshot the result.
    private func autoSolveForScreenshot() {
        wrongGuesses = 1
        finish(solved: true)
    }
}
