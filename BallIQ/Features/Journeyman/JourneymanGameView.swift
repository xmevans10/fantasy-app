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
    /// Set when this board is one round of a Puzzle Blitz run — suppresses this view's result
    /// screen and its `complete` call, reporting to the session instead. See `BlitzSession` for
    /// the contract, and `Keep4GameView.blitz` for the precedence note it shares.
    var blitz: BlitzSession? = nil

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

    /// A wrong guess's price as a share of this board's own maximum — the blitz-safe form of
    /// `nextGuessCost`, which is in points. See `BlitzBoardValue`.
    private var wrongGuessCostShare: String {
        BlitzBoardValue.cost(nextGuessCost,
                             of: JourneymanScoring.maxScore(difficulty: puzzle.difficulty))
    }

    private var effectiveChallenge: ChallengeLink? { duel == nil ? challenge : nil }
    private var isDaily: Bool { duel == nil && (ranked || challenge != nil) }

    private var trimmedGuess: String { guess.trimmingCharacters(in: .whitespaces) }
    private var suggestions: [String] {
        GridGuessSheet.rank(query: trimmedGuess, normalized: normalizedNames)
    }

    /// The `versus_challenges.mode = 'live'` half of a duel (M23) — `duel.live` non-nil is the
    /// whole discriminator between "play it like the timed async duel always has" and "poll for
    /// the opponent's guess count and an early loss". See `LiveJourneymanBoard`'s doc comment for
    /// why that gets an entirely separate body instead of a handful of `if` branches threaded
    /// through this one.
    private var live: LiveDuelSession? { duel?.live }

    /// Leaving the board — ends the whole run inside a blitz rather than dismissing this view.
    /// See `Keep4GameView.close`.
    private func close() {
        if let blitz { blitz.endEarly() } else { dismiss() }
    }

    var body: some View {
        Group {
            if let live, let duel {
                LiveJourneymanBoard(puzzle: puzzle, duel: duel, live: live) { dismiss() }
            } else if let result, blitz == nil {
                // See `Keep4GameView.body` — a blitz round sets `result` as its double-finish
                // guard but must never show a score.
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
            // `LiveJourneymanBoard` owns its own name index and its own start analytics — this
            // solo/async path must stay byte-for-byte what 1.6.0 already shipped, so it skips
            // both rather than growing a branch that could drift the async case by accident.
            guard live == nil else { return }
            if nameIndex.isEmpty {
                nameIndex = await container.puzzles.playerNameIndex(for: puzzle.sport)
                normalizedNames = nameIndex.map { ($0, AnswerMatcher.normalize($0)) }
            }
        }
        .onAppear {
            guard live == nil else { return }
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
            if let blitz {
                BlitzStatusBar(session: blitz)
            } else if let duel {
                DuelStatusBar(session: duel, playerScore: wrongGuesses)
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
                Button { close() } label: {
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
                // Blitz shows a share of this board's maximum instead of points — see
                // `BlitzBoardValue`. (`LiveJourneymanBoard` keeps the points form: a live duel is
                // never a blitz board, and that view is deliberately kept byte-identical to what
                // 1.6.0 shipped.)
                Text(blitz == nil
                     ? String(localized: "Worth \(currentValue) pts")
                     : BlitzBoardValue.remaining(
                        current: currentValue,
                        max: JourneymanScoring.maxScore(difficulty: puzzle.difficulty)))
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
                         ? (blitz == nil
                            ? String(localized: "A wrong guess costs \(nextGuessCost) pts")
                            : String(localized: "A wrong guess costs \(wrongGuessCostShare)"))
                         : String(localized: "Last guess"))
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
        // Blitz: report up, no result screen, no `complete` — see `BlitzSession`. `cleared` is
        // simply "solved", same as Who Am I?: a career path has no chance floor.
        if let blitz {
            result = r
            blitz.finishRound(format: .journeyman, sport: puzzle.sport, puzzleID: puzzle.id,
                              performance: r.performance, cleared: solved)
            return
        }
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

// MARK: - Live duel (M23)

/// The live-duel board: the same career path and guess bar as solo, plus the opponent's guess
/// count ticking beside it (never *what* they guessed — see M23 §1), and a state machine that
/// can end this run the instant a poll shows the opponent solved, whatever the player is
/// mid-keystroke on.
///
/// A wholly separate type rather than a handful of `if let live` branches threaded through
/// `JourneymanGameView`'s existing body: solo Journeyman is live on the App Store in 1.6.0, and
/// this milestone's own brief is explicit that regressing it is worse than shipping no live
/// mode at all. Keeping the two bodies structurally apart — separate `@State`, separate
/// `submit`/`finish` — is what makes "solo is untouched" checkable by reading the diff instead
/// of by trusting it, at the cost of some duplicated guess-bar markup that isn't worth the risk
/// of factoring out of a shipped, working screen mid-milestone.
///
/// Polling lifecycle (start/stop, the ready handshake) is entirely `LiveDuelLobbyView`'s job —
/// it stays mounted underneath `DuelBoard.journeyman(duel, puzzle).view` for the whole race and
/// keeps owning `LiveDuelSession.start()`/`.stop()`, so this board only ever reads `live` and
/// calls its two report methods; it never starts or stops the poll itself.
private struct LiveJourneymanBoard: View {
    let puzzle: JourneymanPuzzle
    let duel: DuelSession
    @ObservedObject var live: LiveDuelSession
    let onDone: () -> Void

    @EnvironmentObject private var container: RepositoryContainer

    @State private var guess = ""
    /// Wrong guesses so far. The *next* guess is number `wrongGuesses + 1`.
    @State private var wrongGuesses = 0
    @State private var wrongShake = false
    /// Set once my own five guesses are spent (or I give up). The race isn't over — §1 says the
    /// opponent can still lose it — so this swaps the guess bar for a waiting panel instead of
    /// ending the run the way solo's `finish(solved: false)` would.
    @State private var myExhausted = false
    /// Set the instant my own solve is submitted, before the server has confirmed it actually
    /// won the race (M23 §3's first-write-wins can still reject it). Blocks further input and
    /// swaps in a "checking" panel rather than declaring victory on a local string match that
    /// hasn't been confirmed server-side — see `checkTerminal`'s doc comment for why the win
    /// itself is never rendered from here.
    @State private var awaitingConfirmation = false
    @State private var result: JourneymanScoring.Result?
    @State private var liveOutcome: LiveRaceOutcome?
    @State private var duelVerdict: DuelVerdict?
    @State private var nameIndex: [String] = []
    @State private var normalizedNames: [(display: String, norm: String)] = []
    @FocusState private var fieldFocused: Bool
    @State private var didLogStart = false
    @State private var startedAt: Date?

    private var currentGuess: Int { wrongGuesses + 1 }
    private var guessesLeft: Int { JourneymanScoring.maxGuesses - wrongGuesses }
    private var currentValue: Int {
        JourneymanScoring.value(guess: currentGuess, difficulty: puzzle.difficulty)
    }
    private var nextGuessCost: Int {
        JourneymanScoring.nextGuessCost(guess: currentGuess, difficulty: puzzle.difficulty)
    }
    private var trimmedGuess: String { guess.trimmingCharacters(in: .whitespaces) }
    private var suggestions: [String] {
        GridGuessSheet.rank(query: trimmedGuess, normalized: normalizedNames)
    }
    private var inputLocked: Bool { myExhausted || awaitingConfirmation || result != nil }

    var body: some View {
        Group {
            if let result, let liveOutcome {
                JourneymanResultView(puzzle: puzzle, result: result, isDaily: false,
                                     duelVerdict: duelVerdict, liveOutcome: liveOutcome,
                                     onDone: onDone)
            } else {
                board
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
                container.track(.gameStarted, ["format": "journeyman", "ranked": "false",
                                               "difficulty": puzzle.difficulty?.rawValue ?? "unrated",
                                               "clubs": "\(puzzle.stints.count)",
                                               "duel": "true", "live": "true"])
            }
            // The session may already be resolved by the time this board appears (a slow
            // launch racing the deadline, or the app returning from background after the poll
            // caught the opponent's solve) — check the state that's already there, not just
            // future changes to it.
            checkTerminal()
        }
        // The single most important behavior in this milestone (§1): the moment a poll reports
        // the opponent solved, this board closes with a loss — on the very next `state`
        // publish, not on the player's next tap, whatever they're mid-typing right now.
        .onChange(of: live.state) { _, _ in checkTerminal() }
    }

    private var board: some View {
        VStack(spacing: 0) {
            // The clock itself is unchanged from an async duel — `duel.secondsRemaining` /
            // `.capturedAt` were snapshotted once from the live poll at hand-off (see
            // `DuelSession.live`'s doc comment), so `DuelStatusBar` needs no live-aware
            // variant. Nothing here ends the run on a clock (M25) — the race ends when somebody
            // solves, which the poll reports.
            DuelStatusBar(session: duel)
            opponentStrip
            if myExhausted {
                waitingOnOpponentPanel
            } else {
                header
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
        }
        .background(Color.appBackground)
    }

    /// Ticks up in real time off the poll — count only, never the guess itself (§1: a wrong
    /// name handed to the other player turns the race into a collaboration).
    private var opponentStrip: some View {
        OpponentProgressStrip(opponentName: duel.opponentName, guesses: live.opponentGuesses,
                              maxGuesses: JourneymanScoring.maxGuesses,
                              finished: live.opponentFinished, solved: live.opponentSolved)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                difficultyChip
                Spacer()
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
        }
    }

    /// A "you're out, they might not be" panel — deliberately not the result screen, because
    /// per §1 this isn't a result yet: the opponent can still lose it.
    private var waitingOnOpponentPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.textMuted)
            Text("OUT OF GUESSES")
                .font(.heading)
                .foregroundStyle(Color.textPrimary)
            Text("Still live — they can still lose it.")
                .font(.body14)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
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
                        .disabled(inputLocked)
                        .submitLabel(.go)
                        .onSubmit { submit(trimmedGuess) }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(Color.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .offset(x: wrongShake ? -8 : 0)

                    Button { submit(trimmedGuess) } label: {
                        Text(awaitingConfirmation ? "…" : "GUESS")
                            .font(.heading)
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.accentFill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(PrimePressStyle())
                    .disabled(inputLocked)
                    .accessibilityHint("Submits the name you entered")
                }

                HStack {
                    Text(guessesLeft > 1
                         ? "A wrong guess costs \(nextGuessCost) pts"
                         : "Last guess")
                        .font(.label12)
                        .foregroundStyle(guessesLeft > 1 ? Color.textMuted : Color.dangerText)
                    Spacer()
                    Button("Give up", action: giveUp)
                        .font(.body14)
                        .foregroundStyle(Color.textMuted)
                        .disabled(inputLocked)
                }
            }
            .padding(16)
            .background(Color.surface)
        }
    }

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
                        .disabled(inputLocked)
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
        guard !trimmed.isEmpty, !inputLocked else { return }
        if AnswerMatcher.matches(trimmed, answer: puzzle.answer) {
            solve()
            return
        }
        wrongGuesses += 1
        guess = ""
        Haptics.reject()
        withAnimation(Motion.snap) { wrongShake = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(Motion.snap) { wrongShake = false }
        }
        // Every guess reports its count, right or wrong, so the opponent's strip ticks (§1).
        Task { await live.reportGuesses(wrongGuesses) }
        if wrongGuesses >= JourneymanScoring.maxGuesses { exhaust() }
    }

    private func giveUp() { exhaust() }

    /// Reports the exhaustion but does **not** end the run — §1: the board stays open until the
    /// opponent finishes too or the clock runs out, because they can still lose it.
    private func exhaust() {
        guard !inputLocked else { return }
        myExhausted = true
        fieldFocused = false
        Task { await live.submitResult(solved: false, guesses: wrongGuesses) }
    }

    /// The one guess that can end the whole challenge on the spot (§3 —
    /// `submit_versus_live_result`'s first correct solve resolves it immediately). Deliberately
    /// does **not** show a result here: `checkTerminal` is the only place that does, once the
    /// server's own answer comes back on the next poll — see its doc comment.
    private func solve() {
        guard !inputLocked else { return }
        awaitingConfirmation = true
        fieldFocused = false
        let guessesAtSolve = currentGuess
        Task { await live.submitResult(solved: true, guesses: guessesAtSolve) }
    }

    /// Called on every `live.state` publish (and once on appear, in case the duel was already
    /// resolved before this board mounted). This — not `solve()` — is the only place a verdict is
    /// ever rendered, because a local "the name matched" is not the same fact as "the server says
    /// I won": `submit_versus_live_result` is first-write-wins, and a solve that lands a beat
    /// after the opponent's, or after the deadline's grace window, has to score as a loss or a
    /// draw, never as a win the player briefly believed they'd earned. This is also what makes
    /// the simultaneous-solve case resolve to exactly one winner: both clients call this off the
    /// same poll cadence, and `LiveRaceOutcome.decide`'s tiebreak is symmetric across them.
    private func checkTerminal() {
        guard result == nil, live.isResolved else { return }
        // `opponentAlreadyWon` folds "resolved" and "they're the one who solved it" together —
        // the exact cue `OpponentProgressStrip`'s own doc comment says this board reads.
        if live.opponentAlreadyWon {
            let r = JourneymanScoring.score(guessesUsed: wrongGuesses, solved: false,
                                            difficulty: puzzle.difficulty)
            finalize(result: r, outcome: .lostToOpponentSolve,
                    theirGuesses: live.opponentGuesses, theirSolved: true)
        } else if live.state?.me.solved == true {
            let r = JourneymanScoring.score(guessesUsed: live.myGuesses, solved: true,
                                            difficulty: puzzle.difficulty)
            finalize(result: r,
                    outcome: live.opponentFinished ? .wonAfterOpponentExhausted : .wonBySolvingFirst,
                    theirGuesses: live.opponentGuesses, theirSolved: false)
        } else {
            // Resolved, nobody solved — the clock ran out (or a server sweep closed an
            // abandoned one). A real draw per §1, whether or not I'd already burned all five
            // guesses.
            let r = JourneymanScoring.score(guessesUsed: wrongGuesses, solved: false,
                                            difficulty: puzzle.difficulty)
            finalize(result: r, outcome: .draw, theirGuesses: live.opponentGuesses, theirSolved: false)
        }
    }

    private func finalize(result r: JourneymanScoring.Result, outcome: LiveRaceOutcome,
                          theirGuesses: Int, theirSolved: Bool) {
        guard result == nil else { return }
        fieldFocused = false
        if r.solved { Haptics.success() }
        liveOutcome = outcome
        duelVerdict = JourneymanResultView.liveDuelVerdict(opponentName: duel.opponentName,
            myResult: r, theirGuesses: theirGuesses, theirSolved: theirSolved)
        // Shown the instant the poll says so — the personal career-log write below is
        // fire-and-forget rather than something the board's transition waits on, because
        // "closes your board immediately" (§1) has to win against a network round trip too.
        withAnimation(Motion.easeOut) { result = r }

        var details = GameResultDetails()
        details.cluesUsed = r.guessesUsed
        details.wrongGuesses = r.wrongGuesses
        details.solved = r.solved
        details.answerName = puzzle.answer.canonical
        details.opponentUserID = duel.opponentUserID
        let detail = RepositoryContainer.SessionDetail(
            mode: .versus, score: r.total,
            maxScore: JourneymanScoring.maxScore(difficulty: puzzle.difficulty),
            correct: r.solved ? 1 : 0, attempted: 1,
            startedAt: startedAt, details: details)
        Task {
            await container.logSession(format: .journeyman, sport: puzzle.sport,
                                       performance: r.performance,
                                       perfect: r.solved && wrongGuesses == 0,
                                       puzzleID: puzzle.id, detail: detail)
        }
    }
}
