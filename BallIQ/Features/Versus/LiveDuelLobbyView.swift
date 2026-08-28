import SwiftUI

/// The ready handshake for a live duel (M23) — "READY", then a wait naming the opponent, then a
/// hand-off straight into the board. One view for the whole duel's client-side lifetime (lobby
/// *and* race), not two views stitched together, because the poll loop that drives the ready
/// screen is the same one the board needs once the race starts: restarting it at the hand-off
/// would risk a gap where a resolution could land unseen.
///
/// Presented full-screen from `VersusView`, the same way `DuelBoard`'s async boards are — see
/// `VersusView.play(_:)`.
struct LiveDuelLobbyView: View {
    let opponentName: String?
    let opponentUserID: String
    let sport: Sport
    /// The board id this duel points at, for `DuelSession.boardID` — the fetch site's own
    /// knowledge of what it asked for, exactly like `RepositoryContainer.startVersusBoard`.
    let puzzleID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: LiveDuelSession

    @State private var puzzle: JourneymanPuzzle?
    /// Snapshotted once, the instant the board actually opens — not recomputed on every poll
    /// tick, so `DuelSession.capturedAt` means what its own doc comment says it means.
    @State private var duel: DuelSession?
    @State private var loadingPuzzle = false
    @State private var puzzleLoadFailed = false
    @State private var readying = false
    @State private var readyError: String?

    init(opponentName: String?, opponentUserID: String, sport: Sport, puzzleID: String,
         challengeID: Int, repository: VersusRepository) {
        self.opponentName = opponentName
        self.opponentUserID = opponentUserID
        self.sport = sport
        self.puzzleID = puzzleID
        _session = StateObject(wrappedValue: LiveDuelSession(challengeID: challengeID,
                                                              puzzleID: puzzleID,
                                                              repository: repository))
    }

    var body: some View {
        Group {
            if let puzzle, let duel {
                DuelBoard.journeyman(duel, puzzle).view
            } else if puzzleLoadFailed {
                closedState(message: String(localized: "Couldn't load the board. Pull to refresh from Versus and try again."))
            } else if session.isResolved && !session.bothReady {
                // Never got both sides ready: the duel's own 24h expiry (or a same-poll no-show
                // sweep) closed it before the race could start — not a loss, just a dead link.
                closedState(message: String(localized: "This duel closed before it could start, likely nobody showed up in time."))
            } else if session.bothReady {
                openingBoard
            } else if session.iAmReady {
                waitingOnOpponent
            } else {
                readyPrompt
            }
        }
        .background(Color.appBackground)
        .task { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            // The poll is also the liveness detector (M23 §2): backgrounding stops it rather
            // than letting it run unseen, and the server-side clock resolves the duel regardless.
            if phase == .active { session.start() } else { session.stop() }
        }
        .onChange(of: session.bothReady) { _, ready in
            if ready { Task { await openBoard() } }
        }
    }

    // MARK: - Ready / waiting

    private var readyPrompt: some View {
        VStack(spacing: 18) {
            Spacer()
            header
            VStack(spacing: 10) {
                Text("FIRST TO SOLVE WINS")
                    .font(.label12)
                    .foregroundStyle(Color.accentText)
                Text(opponentName.map { String(localized: "\($0) is on the other side of this one.") }
                     ?? String(localized: "Your opponent is on the other side of this one."))
                    .font(.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.textPrimary)
                Text("Same career path, same clock, both of you racing at once. Neither board opens until you're both ready.")
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            .heroReveal(0)
            if let readyError {
                Text(readyError).font(.label12).foregroundStyle(Color.dangerText)
            }
            Button {
                Haptics.tap()
                Task { await ready() }
            } label: {
                Text(readying ? "READYING…" : "READY").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            .disabled(readying)
            .padding(.horizontal, 40)
            .heroReveal(1)
            Spacer()
            Spacer()
        }
        .padding(16)
    }

    private var waitingOnOpponent: some View {
        VStack(spacing: 18) {
            Spacer()
            header
            VStack(spacing: 10) {
                ProgressView().tint(Color.accentText)
                Text(opponentName.map { String(localized: "Waiting for \($0)…") }
                     ?? String(localized: "Waiting for your opponent…"))
                    .font(.title)
                    .foregroundStyle(Color.textPrimary)
                Text("You're in. The board opens the instant they ready up, leave this open, or come back to it from Versus any time before it expires.")
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                if session.pollFailing {
                    Text("Having trouble reaching the server. Retrying…")
                        .font(.label11)
                        .foregroundStyle(Color.warningText)
                }
            }
            Spacer()
            Spacer()
        }
        .padding(16)
    }

    private var openingBoard: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().tint(Color.accentText)
            Text("Both ready. Opening the board…")
                .font(.label12)
                .foregroundStyle(Color.textMuted)
            Spacer()
        }
    }

    private func closedState(message: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.textMuted)
                .frame(width: 84, height: 84)
                .background(Color.surfaceMuted)
                .clipShape(Circle())
            Text("Duel closed").font(.title).foregroundStyle(Color.textPrimary)
            Text(message)
                .font(.label12)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Button { dismiss() } label: {
                Text("BACK TO VERSUS").ctaLabel()
            }
            .buttonStyle(PrimePressStyle())
            .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.textMuted)
            }
            .accessibilityLabel("Close")
            Spacer()
            Label(sport.displayName, systemImage: PuzzleFormat.journeyman.symbol)
                .font(.label12)
                .foregroundStyle(Color.textMuted)
        }
    }

    // MARK: - Actions

    private func ready() async {
        guard !readying else { return }
        readying = true
        readyError = nil
        defer { readying = false }
        do { try await session.ready() }
        catch { readyError = String(localized: "Couldn't ready up. Check your connection and try again.") }
    }

    private func openBoard() async {
        guard puzzle == nil, !loadingPuzzle else { return }
        loadingPuzzle = true
        defer { loadingPuzzle = false }
        guard let fetched = await session.loadPuzzle(JourneymanPuzzle.self) else {
            puzzleLoadFailed = true
            return
        }
        // `secondsRemaining` no longer drives anything on this path — the race ends when the
        // poll reports a solve (`checkTerminal` in `JourneymanGameView`), never on a countdown —
        // so this is `state.timeLimitSeconds`, the par both sides are scored against, not a
        // recomputed "time left". `capturedAt` still has to be the instant the board actually
        // opens: it's the anchor `DuelStatusBar` reads for the bot-elapsed clock on every other
        // duel type, and duels share one `DuelSession` shape (AGENTS.md §4).
        let now = Date()
        duel = DuelSession(challengeID: session.challengeID, format: .journeyman, boardID: puzzleID,
                           opponentUserID: opponentUserID, opponentName: opponentName,
                           secondsRemaining: session.parSeconds, capturedAt: now,
                           live: session)
        puzzle = fetched
    }
}

#Preview {
    // A config that never resolves a real host — the preview only ever renders the ready/waiting
    // states, which don't perform a network round trip until a button is tapped.
    let client = SupabaseClient(config: SupabaseConfig(url: URL(string: "https://preview.invalid")!,
                                                        anonKey: "preview"))
    return LiveDuelLobbyView(opponentName: "hoopsfan", opponentUserID: "opp", sport: .nba,
                             puzzleID: "journeyman-nba-2026-08-01", challengeID: 1,
                             repository: VersusRepository(client: client))
}
