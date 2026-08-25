import SwiftUI

/// Puzzle Blitz — setup, then real boards back to back until the clock stops, then one score.
///
/// This view owns the run and nothing else: it draws boards from `BlitzRoundLoader`, hands each
/// one to that format's **existing** game view with a `blitz` session attached, and watches the
/// session for "board finished" / "run over". The boards themselves are untouched games — the
/// same `Keep4GameView` the daily uses, the same `JourneymanGameView`, the same headshots and
/// crests and stat grids — which is the only way this mode can satisfy BALLIQ_SPEC §1 theme 1
/// (best-surface parity) without four blitz-flavoured re-implementations to keep in step.
///
/// The one thing a blitz board does differently is what happens when it ends: it reports into
/// `BlitzSession` instead of showing its own result screen and banking its own XP. See
/// `BlitzSession` for that contract, and `BlitzRunSummary` for why no score exists until here.
struct BlitzGameView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var config = BlitzConfig.load()
    /// The primary sport `GameSetupScreen` tracks. Seeded from the last sport played, then kept
    /// in step with `config.sports` by the scaffold itself.
    @State private var sport: Sport = .nfl
    @State private var phase: Phase = .setup
    @State private var session: BlitzSession?
    @State private var loader: BlitzRoundLoader?
    @State private var board: BlitzBoard?
    @State private var summary: BlitzRunSummary?
    @State private var rewards: RepositoryContainer.SessionRewards?
    @State private var beatHighScore = false
    /// Whether the run ended because the player left a board rather than because the clock ran
    /// out — the result screen's headline is the only thing that reads it.
    @State private var endedEarly = false

    private let store = LocalBlitzStore()

    private enum Phase: Equatable { case setup, loading, playing, empty, result }

    var body: some View {
        Group {
            switch phase {
            case .setup:
                BlitzSetupView(config: $config, sport: $sport,
                               onStart: { Task { await start() } },
                               onClose: { dismiss() })
            case .loading:
                loadingBoard
            case .playing:
                playBoard
            case .empty:
                emptyBoard
            case .result:
                if let summary {
                    BlitzResultView(summary: summary,
                                    highScore: store.highScore(for: summary.config.duration),
                                    beatHighScore: beatHighScore, endedEarly: endedEarly,
                                    rewards: rewards,
                                    onPlayAgain: { Task { await replay() } },
                                    onDone: { dismiss() })
                }
            }
        }
        .background(Color.appBackground)
        .task {
            sport = container.sportFilter.sport ?? .nfl
            if !config.sports.contains(sport) { config.sports = [sport] }
            // Warm the arcade pool for the sport most likely to come up while the player is
            // still reading the setup screen — same trick Over/Under and Draft & Spin use, and
            // the reason a blitz opens on a board rather than a spinner.
            container.catalog.prefetchDraftSpinSample(for: sport)
            if DebugLaunch.autoOpenBlitz && !DebugLaunch.holdBlitzSetup { await start() }
        }
    }

    // MARK: - Boards

    @ViewBuilder
    private var playBoard: some View {
        if let session, let board {
            // The board is wrapped in `BlitzRunObserver` rather than carrying the `.onChange`
            // modifiers itself. `session` is held here in plain `@State`, which stores the
            // reference but does **not** subscribe to its `@Published` properties — so an
            // `.onChange(of: session.rounds.count)` written at this level never re-evaluates and
            // the run silently stalls on its first board with the clock still running. (Found by
            // playing one, not by reading it: the status bar kept ticking and said "1 done"
            // while the finished board stayed on screen.) The observer declares the session
            // `@ObservedObject`, which is what actually subscribes.
            BlitzRunObserver(session: session,
                             onRoundFinished: advance,
                             onRunOver: { Task { await finish() } }) {
                // `.id(board.id)` is load-bearing, not hygiene: without it SwiftUI reuses the
                // same view instance across two boards of the same format and every `@State` in
                // it — the blind card order, the revealed clue count, the guesses already spent —
                // carries over into the next puzzle.
                boardView(board, session: session)
                    .id(board.id)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func boardView(_ board: BlitzBoard, session: BlitzSession) -> some View {
        switch board {
        case .keep4(let puzzle):
            Keep4GameView(puzzle: puzzle, ranked: false, blitz: session)
        case .whoami(let puzzle):
            WhoAmIGameView(puzzle: puzzle, ranked: false, blitz: session)
        case .journeyman(let puzzle):
            JourneymanGameView(puzzle: puzzle, ranked: false, blitz: session)
        case .overunder(let round, let sport):
            OverUnderGameView(blitz: session, blitzRound: round, blitzSport: sport)
        }
    }

    private var loadingBoard: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Color.accentText)
            Text("DEALING PUZZLES").font(.label12).foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    /// A real empty state, not a spinner that never resolves: the chosen sport/format mix has no
    /// content at all (a sport whose pools haven't been minted yet, or a fully offline first
    /// launch). Says which knob to turn rather than blaming the network.
    private var emptyBoard: some View {
        VStack(spacing: 16) {
            EmptyStateView(symbol: "bolt.slash",
                           title: "No puzzles for this mix",
                           message: "Nothing's available for the sports and formats you picked. Try adding a sport or another puzzle type.")
            Button { withAnimation(Motion.easeOut) { phase = .setup } } label: {
                Text("BACK TO SETUP").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    // MARK: - Run lifecycle

    private func start() async {
        config.save()
        withAnimation(Motion.easeOut) { phase = .loading }
        let loader = BlitzRoundLoader(container: container, config: config)
        // Pools are warmed *before* the clock starts. A run whose first ten seconds went on a
        // cold fetch would charge the player for the network, which is the one thing a timed
        // mode must never do.
        guard await loader.warm() else {
            withAnimation(Motion.easeOut) { phase = .empty }
            return
        }
        self.loader = loader
        let session = BlitzSession(config: config)
        self.session = session
        self.rewards = nil
        self.summary = nil
        self.beatHighScore = false
        self.endedEarly = false
        container.track(.gameStarted, ["format": "blitz",
                                       "seconds": String(config.duration.rawValue),
                                       "sports": String(config.sports.count),
                                       "types": String(config.formats.count)])
        board = loader.next()
        session.beginRound()
        withAnimation(Motion.easeOut) { phase = board == nil ? .empty : .playing }
    }

    /// PLAY AGAIN — a fresh clock and a fresh loader on the same config. Deliberately re-warms
    /// rather than reusing the last run's loader: its `served` set would carry over and the
    /// second run would draw from a pool the first one had already thinned.
    private func replay() async {
        Haptics.tap()
        await start()
    }

    /// One board finished. Serve the next, or end the run if the clock is out (which
    /// `BlitzSession.finishRound` has already decided) or the pools are exhausted.
    private func advance() {
        guard let session, !session.isOver else { return }
        guard session.acceptsNewRound() else { session.endEarly(); return }
        guard let next = loader?.next() else {
            // Ran out of boards before running out of time. Honest end to the run rather than a
            // stall — the result screen shows what was actually played.
            session.endEarly()
            return
        }
        withAnimation(Motion.easeOut) { board = next }
        session.beginRound()
    }

    /// Banks the whole run: one career-log row, one XP award, one personal-best check.
    ///
    /// **One row for the run, not one per board.** A blitz is a session in exactly the sense
    /// Over/Under's is, and writing fifteen `game_results` rows for five minutes of play would
    /// swamp every volume and accuracy stat in the career log with practice boards. `mode:
    /// .practice` is the honest tag (infinitely repeatable, so `countsForRecords` is false) and
    /// `ranked: false` is forced by the shape of the mode: a run spans sports, so there is no
    /// single rating it could move.
    private func finish() async {
        guard let session, summary == nil else { return }
        endedEarly = session.acceptsNewRound()
        let run = session.summary()
        summary = run
        beatHighScore = store.recordScore(run.total, for: run.config.duration)
        Haptics.commit()
        let detail = RepositoryContainer.SessionDetail(
            mode: .practice, score: run.total, maxScore: run.maxPossible,
            correct: run.cleared, attempted: run.played,
            startedAt: session.startedAt, details: Self.buildDetails(run))
        rewards = await container.complete(
            format: .blitz,
            // The sport the run drew most of its boards from — a single-sport run reports that
            // sport truthfully, and a mixed run has to report *something* for a column that is
            // `not null`. Never used for rating (the run is unranked), only for "which sport do
            // I play" stats, where the modal sport is the honest answer.
            sport: Self.dominantSport(run) ?? sport,
            performance: run.performance, perfect: run.played > 0 && run.cleared == run.played,
            puzzleID: "blitz-\(run.config.duration.rawValue)-\(PuzzleStore.localDayString())-\(UUID().uuidString.prefix(8))",
            ranked: false, detail: detail)
        withAnimation(Motion.easeOut) { phase = .result }
    }

    /// The sport that supplied the most boards, ties broken by `Sport.allCases` order so the same
    /// run always reports the same sport. Nil on an empty run.
    static func dominantSport(_ run: BlitzRunSummary) -> Sport? {
        var counts: [Sport: Int] = [:]
        for round in run.rounds { counts[round.sport, default: 0] += 1 }
        return Sport.allCases
            .filter { counts[$0] != nil }
            .max { (counts[$0] ?? 0, $1.rawValue) < (counts[$1] ?? 0, $0.rawValue) }
    }

    /// The blitz slice of `GameResultDetails`. Pure and static so the run→row mapping is testable
    /// without driving a session (the same reason `Keep4GameView.buildDetails` is).
    static func buildDetails(_ run: BlitzRunSummary) -> GameResultDetails {
        var details = GameResultDetails()
        details.bestCombo = run.bestStreak
        return details
    }
}

/// Subscribes to a `BlitzSession` so the run can actually advance — see `BlitzGameView.playBoard`
/// for why this can't live on the host itself.
///
/// Deliberately does nothing but observe: the board it wraps is passed through untouched, so this
/// adds a subscription and not a layout.
private struct BlitzRunObserver<Content: View>: View {
    @ObservedObject var session: BlitzSession
    let onRoundFinished: () -> Void
    let onRunOver: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .onChange(of: session.rounds.count) { _, _ in onRoundFinished() }
            .onChange(of: session.isOver) { _, over in if over { onRunOver() } }
    }
}

#Preview {
    BlitzGameView().environmentObject(RepositoryContainer.make())
}
