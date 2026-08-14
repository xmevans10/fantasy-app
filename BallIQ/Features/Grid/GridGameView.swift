import SwiftUI

/// The Grid (M5 Phase E, Pro-only): a 3x3 team x decade board, 9 total guesses (one attempt
/// per cell — decisions are final, same posture as Keep4). Ranked through the normal
/// `complete(...)` pipeline; content comes only from `PuzzleRepository.gridPuzzle` (server-
/// generated, no offline bundle — see that protocol's doc comment).
struct GridGameView: View {
    /// Set when this view was opened from a `balliq://challenge` link: it pins the sport and the
    /// board's day, skips the setup screen, and carries the challenger's score into the result.
    var challenge: ChallengeLink? = nil
    /// Set when this board is being played as a timed Versus duel. Server-authoritative clock;
    /// see `DuelSession`. Mutually exclusive with `challenge` in practice; if both are somehow
    /// set, `duel` wins — it's the server-mediated seam, and a duel's board may not even be
    /// today's daily, so it must never carry the dare language a real `ChallengeLink` does.
    var duel: DuelSession? = nil
    /// The exact board the duel names, fetched by id by the caller (`VersusView`). Bypasses the
    /// daily/practice resolution in `load(...)` entirely — a duel compares two runs on one
    /// board, so it must be the one the challenge points at, never one this device happened to
    /// resolve. `nil` only if the caller failed to fetch it, which degrades to the "No Grid
    /// today" empty state rather than crashing.
    var duelPuzzle: GridPuzzle? = nil

    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var puzzle: GridPuzzle?
    @State private var loading = true
    /// Index (row*3+col) -> the matched valid-answer name, once correctly guessed.
    @State private var solved: [Int: String] = [:]
    @State private var wrong: Set<Int> = []
    /// What was actually typed on each miss — kept only for the crowd-rarity log.
    @State private var wrongNames: [Int: String] = [:]
    @State private var activeCell: Int?
    /// Sport-wide player names powering the guess autocomplete (empty offline → free text).
    @State private var nameIndex: [String] = []
    @State private var result: (score: Int, correctCount: Int)?
    @State private var rewards: RepositoryContainer.SessionRewards?
    /// Set at `load`'s `track(.gameStarted)` site — `nil` only if `finish` is somehow reached
    /// without a load (shouldn't happen), in which case the session is logged untimed rather
    /// than crashing.
    @State private var startedAt: Date?

    @State private var showingSetup = true
    @State private var sport: Sport = .nfl
    /// A practice board is any board that isn't today's daily — spawned from the setup screen's
    /// "new random grid". Practice runs award **nothing**: no rating, no XP, no arcade score, no
    /// crowd-rarity log. That's not stinginess, it's the only non-exploitable option — the board
    /// is re-rollable without limit, so anything it awarded could be farmed by re-rolling until
    /// an easy board came up. `complete(...)` is skipped entirely rather than called with
    /// `ranked: false`, because `recordCompletion` still adds XP on the unranked path.
    @State private var isPractice = false
    /// Set once the random pool is exhausted, so the empty state can say so honestly rather
    /// than claiming there's no Grid at all.
    @State private var practicePoolEmpty = false
    /// The sport's membership relation, once fetched — the input `GridLocalGenerator` builds
    /// practice boards from. Held for the whole session so a re-roll is instant and offline.
    @State private var memberships: GridMembershipIndex?
    /// Combo keys already played this session. Feeds the generator's rejection set so "new random
    /// grid" can't hand back the board just finished — the client-side twin of the `grid_history`
    /// trailing window the server mint uses.
    @State private var playedCombos: Set<String> = []
    /// A challenge named a `(sport, day)` this device's pool has no board for. Distinct from
    /// "No Grid today": today's board may well exist, it just isn't the one being challenged —
    /// and quietly serving a *different* board would compare two scores set on two grids.
    @State private var challengeBoardMissing = false
    /// Whether the board on screen is the row actually minted for today, rather than the modulo
    /// pick `RemotePuzzleRepository.pick` falls back to when the day has no row.
    ///
    /// This is NOT the same as "not practice", which is what it was first written as. Live today
    /// (2026-07-27): baseball's newest minted board is 2026-07-08 — the daily Grid cron is paused
    /// (§4.1) — so a baseball daily *is* a fallback pick. Sharing that as "today's MLB Grid" would
    /// mint a challenge naming a day whose board doesn't exist, and every recipient would hit
    /// "That board's gone". Only a genuinely canonical board can be challenged.
    @State private var isCanonicalDaily = false
    /// The challenge actually in force. Mirrors the `challenge` input so it can be *cleared* when
    /// the player declines the missing board and takes today's instead — otherwise the result
    /// screen would post a head-to-head between two scores set on two different grids.
    @State private var activeChallenge: ChallengeLink?
    private var attemptedCount: Int { solved.count + wrong.count }

    var body: some View {
        Group {
            if let result {
                GridResultView(sport: sport, score: result.score, correctCount: result.correctCount,
                               puzzle: puzzle, solved: solved,
                               rewards: rewards, isDaily: duel == nil && isCanonicalDaily,
                               challenge: duel == nil ? activeChallenge : nil,
                               duelVerdict: duel?.ladder?.verdict(myHits: result.correctCount),
                               onDone: { dismiss() })
            } else if challengeBoardMissing, let challenge {
                EmptyStateView(symbol: "calendar.badge.exclamationmark",
                               title: "That board's gone",
                               message: "The \(challenge.displayDay) \(challenge.sport.displayName) grid isn't available on this device. Play today's grid instead and set your own score.",
                               actionTitle: "Today's grid",
                               action: {
                                   challengeBoardMissing = false
                                   activeChallenge = nil   // different board — nothing to compare
                                   Task { await load() }
                               })
            } else if showingSetup {
                GameSetupScreen(formatName: "The Grid", title: "Pick your sport",
                                startLabel: "Open the grid", sport: $sport,
                                onStart: { Task { await load() } },
                                onClose: { dismiss() },
                                secondaryLabel: "New random grid",
                                onSecondary: { Task { await load(random: true) } }) { EmptyView() }
            } else if loading {
                ProgressView().tint(Color.accentText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let puzzle {
                board(puzzle)
            } else if practicePoolEmpty {
                // Distinct from "No Grid today": the daily may well exist, there just isn't a
                // *second* board to re-roll into. Real today — baseball has one board ever
                // minted, soccer three — so this state is reachable, not theoretical.
                EmptyStateView(symbol: "shuffle", title: "No other grids yet",
                              message: "\(sport.displayName) has no past grids to shuffle into yet. Try the daily grid, or another sport.",
                              actionTitle: "Back", action: { showingSetup = true; practicePoolEmpty = false })
            } else {
                EmptyStateView(symbol: "square.grid.3x3", title: "No Grid today",
                              message: "Check back tomorrow for a new Grid.",
                              actionTitle: "Close", action: { dismiss() })
            }
        }
        .background(Color.appBackground)
        .task {
            // Duel wins over challenge (see `duel`'s doc comment). Bypasses `load(...)`
            // entirely: a duel's board arrives already resolved, so there is no daily/practice
            // pick to make and no setup screen to show.
            if let duel {
                puzzle = duelPuzzle
                sport = duelPuzzle?.sport ?? sport
                showingSetup = false
                loading = false
                startedAt = Date()
                container.track(.gameStarted, ["format": "grid", "sport": sport.rawValue, "mode": "duel"])
                Task { nameIndex = await container.puzzles.playerNameIndex(for: sport) }
                return
            }
            // A challenge names its own sport; honouring the local filter here would open the
            // wrong sport's board and then fail to find the challenged day on it.
            if let challenge {
                sport = challenge.sport
                activeChallenge = challenge
                await load(challenge: challenge)
                return
            }
            sport = container.sportFilter.sport ?? .nfl
            // Screenshot flows target the board/result — skip the setup screen, unless the
            // setup screen is itself the thing being captured.
            if DebugLaunch.autoOpenGrid && !DebugLaunch.holdGridSetup { await load() }
        }
        .sheet(isPresented: Binding(get: { activeCell != nil }, set: { if !$0 { activeCell = nil } })) {
            if let activeCell, let puzzle {
                GridGuessSheet(
                    prompt: cellPrompt(puzzle, index: activeCell),
                    names: nameIndex,
                    usedNames: Array(solved.values),
                    onGuess: { submitGuess($0) },
                    onCancel: { self.activeCell = nil }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func load(random: Bool = false, challenge: ChallengeLink? = nil) async {
        showingSetup = false
        isPractice = random
        // GameSetupScreen warms this for the normal path, but `-screenshotGrid*` skips the setup
        // screen entirely — without this the board's row crests fall back to the ESPN CDN.
        container.catalog.warmIdentities(for: sport)
        // The setup screen's pick is already one concrete sport — never `.all`, which
        // carries no sport and would fetch every sport's grid row and silently pick
        // whichever sorts first (a real bug the old filter-derived flow hit).
        let resolvedFilter = SportFilter(rawValue: sport.rawValue) ?? .nfl
        if random {
            puzzle = await practiceBoard(filter: resolvedFilter)
            practicePoolEmpty = puzzle == nil
        } else if let challenge, let day = challenge.date {
            // No new repository call: `gridPuzzle(for:date:)` already resolves the row whose
            // `active_date` matches the date it's handed (`RemotePuzzleRepository.pick`), so
            // asking for the challenge's day *is* asking for the challenged board.
            let pick = await container.puzzles.gridPuzzle(for: resolvedFilter, date: day)
            // `isCanonicalToday` false means the pool held no row for that day and `pick` fell
            // back to a modulo choice — a different board wearing the right date. Refuse it.
            if let pick, pick.isCanonicalToday {
                puzzle = pick.content
                isCanonicalDaily = true
            } else {
                puzzle = nil
                challengeBoardMissing = true
            }
        } else {
            let pick = await container.puzzles.gridPuzzle(for: resolvedFilter, date: Date())
            puzzle = pick?.content
            isCanonicalDaily = pick?.isCanonicalToday ?? false
        }
        guard !challengeBoardMissing else { loading = false; return }
        startedAt = Date()
        container.track(.gameStarted, ["format": "grid", "sport": sport.rawValue,
                                       "mode": random ? "practice" : (challenge == nil ? "daily" : "challenge")])
        if challenge != nil {
            container.track(.challengeStarted, ["format": ChallengeLink.Format.grid.rawValue,
                                                "sport": sport.rawValue])
        }
        loading = false
        // Populate the guess autocomplete in the background — the board is playable without it.
        Task { nameIndex = await container.puzzles.playerNameIndex(for: sport) }
        if DebugLaunch.autoSubmitGrid, let puzzle { autoSolveForScreenshot(puzzle) }
    }

    /// A practice board: generated on-device from the sport's membership index when we have one,
    /// otherwise the old draw from the minted pool.
    ///
    /// Local generation is preferred because the pool is the constraint the whole feature exists
    /// to remove — 41 boards have ever been minted across all five sports, baseball has one, so
    /// "new random grid" was re-serving the same handful. A generated board is instant, works
    /// offline, and never runs out. The pool draw stays as the fallback for a first launch that
    /// can't reach the RPC.
    ///
    /// This path is **practice only**, by construction: `load(random:)` is the sole caller and it
    /// has already set `isPractice`, which makes `finish` skip `complete(...)`, the arcade score
    /// and the crowd-rarity log entirely. `GridLocalGenerator` and `tools/ingest/grid.py` are two
    /// generators that could drift; keeping the local one out of ranked play is what makes that
    /// drift a cosmetic risk rather than a competitive-integrity one.
    private func practiceBoard(filter: SportFilter) async -> GridPuzzle? {
        if memberships == nil { memberships = await container.puzzles.gridMembershipIndex(for: sport) }
        if let memberships {
            let generator = GridLocalGenerator(index: memberships)
            // Genuinely random per re-roll (the clock is in the seed), not a deterministic
            // sequence — same posture as Draft & Spin, where a spin the player can predict
            // stops being a spin. The generator itself stays seed-reproducible, which is what
            // the tests pin and what a "share this board" feature would key on later.
            let seed = SeededGenerator.stableHash(
                "grid-practice-\(sport.rawValue)-\(playedCombos.count)-\(Date().timeIntervalSince1970)")
            if let board = generator.board(seed: seed, recentlyServed: playedCombos) {
                playedCombos.insert(board.comboKey)
                return board.puzzle
            }
        }
        // Exclude today's canonical board so a re-roll can't hand back the daily the player
        // came here to play — and, since practice awards nothing, can't be used to scout it.
        let today = OverUnderRoundGenerator.dayString(Date())
        return await container.puzzles.randomGridPuzzle(for: filter, excludingDate: today)
    }

    // MARK: - Board

    private func board(_ puzzle: GridPuzzle) -> some View {
        VStack(spacing: 0) {
            if let duel {
                // A blown clock still resolves the duel — `finish` scores whatever's solved so
                // far (unattempted cells simply don't add to the numerator) rather than
                // abandoning the run. `solved` only ever holds confirmed-correct guesses (wrong
                // ones go to `wrong`), so this is a genuine live score, not just a progress count.
                DuelTimerBar(session: duel, playerScore: solved.count) { finish(puzzle) }
            }
            header
            Spacer(minLength: 0)
            gridLayout(puzzle).padding(16)
            Spacer(minLength: 0)
            footer(puzzle)
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
            // Say up front that a practice board doesn't count — finding that out only on the
            // result screen, after nine final-answer guesses, would feel like a bait and switch.
            Text(isPractice ? "THE GRID · PRACTICE" : "THE GRID")
                .font(.label12).foregroundStyle(Color.proText)
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
        let cols = puzzle.cols.count
        let columns = [GridItem(.fixed(72))] + puzzle.cols.map { _ in GridItem(.flexible()) }
        let totalSlots = (puzzle.rows.count + 1) * (cols + 1)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<totalSlots, id: \.self) { slot in
                let row = slot / (cols + 1)
                let col = slot % (cols + 1)
                if row == 0 {
                    if col == 0 {
                        Color.clear.frame(height: 44)
                    } else {
                        axisCell(puzzle, axis: puzzle.cols[col - 1], fontSize: 14, minHeight: 44)
                    }
                } else if col == 0 {
                    axisCell(puzzle, axis: puzzle.rows[row - 1], fontSize: 14, minHeight: 44)
                } else {
                    answerCell(puzzle, row: row - 1, col: col - 1)
                }
            }
        }
    }

    /// One axis header. Both dimensions render through this now — before the board went
    /// symmetric, the column headers were always decade text and the row headers always team
    /// chips, so each had its own hardcoded builder. A team axis still gets the real crest +
    /// color chip; every other kind is a text label.
    @ViewBuilder
    private func axisCell(_ puzzle: GridPuzzle, axis: GridPuzzle.GridAxis,
                          fontSize: CGFloat, minHeight: CGFloat) -> some View {
        if axis.kind == .team {
            TeamAbbrChip(sport: puzzle.sport, abbr: axis.teamAbbr, league: axis.teamLeague,
                         fontSize: fontSize, minHeight: minHeight, showLogo: true,
                         displayText: axis.label)
        } else {
            Text(axis.label)
                .font(.custom(FontName.condBlack, size: fontSize))
                .foregroundStyle(Color.textPrimary)
                // Stat labels ("1,000+ Rush Yds") are far longer than the decades this cell used
                // to hold, so they wrap to two lines before shrinking rather than scaling a
                // single line down to unreadable.
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .background(Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
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

    /// Phrased for the board shape actually on screen — "the team and the era" was wrong the
    /// moment a board could be teams x teams or teams x stats.
    private func footer(_ puzzle: GridPuzzle) -> some View {
        Text(puzzle.instructions)
            .font(.label11).foregroundStyle(Color.textMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 16)
    }

    private func cellPrompt(_ puzzle: GridPuzzle, index: Int) -> String {
        puzzle.prompt(row: index / 3, col: index % 3)
    }

    // MARK: - Logic

    private func submitGuess(_ guess: String) {
        guard let index = activeCell, let puzzle else { return }
        let row = index / 3, col = index % 3
        activeCell = nil

        if puzzle.isCorrect(row: row, col: col, guess: guess) {
            let matched = puzzle.cell(row: row, col: col).validAnswerNames.first { name in
                AnswerMatcher.matches(guess, answer: .init(canonical: name, aliases: []))
            } ?? guess
            solved[index] = matched
            Haptics.success()
        } else {
            wrong.insert(index)
            wrongNames[index] = guess
            Haptics.reject()
        }

        if attemptedCount >= 9 { finish(puzzle) }
    }

    private func finish(_ puzzle: GridPuzzle) {
        // The duel timer and the ninth guess can both try to finish the same run (a guess
        // landing right as the clock hits zero) — idempotent rather than relying on either
        // caller to coordinate.
        guard result == nil else { return }
        let performance = Double(solved.count) / 9.0
        // A duel is never ranked and never a daily (see `duel`'s doc comment) — same distinction
        // Keep4's duel branch makes via `PlayMode`.
        let mode: PlayMode = duel != nil ? .versus : (isPractice ? .practice : .daily)
        let detail = Self.buildSessionDetail(puzzle: puzzle, solved: solved, wrong: wrong,
                                             mode: mode, startedAt: startedAt,
                                             opponentUserID: duel?.opponentUserID)
        let score = detail.score
        if let duel {
            // `duel.boardID` is the real `puzzles.id` the board was fetched by
            // (`"grid-<sport>-<yyyy-mm-dd>"`) — `GridPuzzle` content doesn't embed its own row
            // id, so the session carries it rather than each game view inventing a placeholder.
            Task {
                await container.logSession(format: .grid, sport: sport, performance: performance,
                                           perfect: solved.count == 9, puzzleID: duel.boardID,
                                           detail: detail)
                await container.submitDuelResult(duel, performance: performance,
                                                 elapsed: Date().timeIntervalSince(startedAt ?? Date()))
                withAnimation(Motion.snap) { result = (score, solved.count) }
            }
            return
        }
        // A practice board is re-rollable without limit, so it earns no rating/XP/arcade score —
        // that's still true. What changed is that the reps are no longer thrown away: `logSession`
        // writes them to the career log (skipping XP/streak/rating, unlike `complete`), so accuracy
        // and volume stats see practice play while `PlayMode.countsForRecords` (false for
        // `.practice`) keeps it out of personal bests.
        guard !isPractice else {
            Task {
                await container.logSession(format: .grid, sport: sport, performance: performance,
                                           perfect: solved.count == 9,
                                           puzzleID: "grid-practice-\(sport.rawValue)", detail: detail)
                withAnimation(Motion.snap) { result = (score, solved.count) }
            }
            return
        }
        let day = OverUnderRoundGenerator.dayString(Date())
        let dailyID = "grid-\(sport.rawValue)-\(day)"
        let ranked = !container.hasCompletedToday(puzzleID: dailyID)
        let attempts = solved.map { (cell: $0.key, name: $0.value, correct: true) }
            + wrongNames.map { (cell: $0.key, name: $0.value, correct: false) }
        Task {
            rewards = await container.complete(format: .grid, sport: sport, performance: performance,
                                               perfect: solved.count == 9, puzzleID: dailyID, ranked: ranked,
                                               detail: detail)
            // Grid's puzzle is daily — only the first (ranked) run of the day posts to the
            // weekly board, or an unranked replay could farm it by re-solving the same puzzle.
            if ranked { await container.submitArcadeScore(game: .grid, sport: sport, score: score) }
            // Crowd-rarity log feeds "X% picked this" — ranked runs only, so replays can't
            // pad an answer's numbers by re-solving the same board.
            if ranked { await container.logGridGuesses(day: day, sport: sport, attempts: attempts) }
            withAnimation(Motion.snap) { result = (score, solved.count) }
        }
    }

    /// Builds the log entry for a finished grid — split out of `finish` so the score/star math and
    /// the missed-cell-header logic can be unit tested without standing up the view. `wrong` is
    /// exactly "attempted but unsolved" here because `finish` only ever runs once all 9 cells have
    /// a final answer, never partway through.
    static func buildSessionDetail(puzzle: GridPuzzle, solved: [Int: String], wrong: Set<Int>,
                                   mode: PlayMode, startedAt: Date?,
                                   opponentUserID: String? = nil) -> RepositoryContainer.SessionDetail {
        let totalStars = solved.keys.reduce(0) { sum, index in
            sum + puzzle.cell(row: index / 3, col: index % 3).rarityStars
        }
        var details = GameResultDetails()
        details.cellsSolved = solved.count
        details.rarityStars = totalStars
        // Both axis labels per missed cell, e.g. ["LAL", "30+ PPG season"] — powers the "nemesis
        // category" stat. Sorted by index for deterministic ordering (a `Set` iterates arbitrarily).
        details.missedCellHeaders = wrong.sorted().flatMap { index -> [String] in
            [puzzle.rows[index / 3].label, puzzle.cols[index % 3].label]
        }
        details.opponentUserID = opponentUserID
        // 9 solves x 100, plus up to 5 rarity stars x 20 each — the true ceiling (a perfect board
        // of nine 5-star cells) is 1800.
        return RepositoryContainer.SessionDetail(mode: mode, score: solved.count * 100 + totalStars * 20,
                                                 maxScore: 1800, correct: solved.count, attempted: 9,
                                                 startedAt: startedAt, details: details)
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
