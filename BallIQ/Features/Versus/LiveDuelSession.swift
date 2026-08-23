import Foundation

/// One `versus_live_state` poll, decoded straight off the RPC's jsonb (M23 §3 — a fixed wire
/// contract shared with the server and Journeyman work streams; do not rename a field without
/// updating all three).
///
/// **Decoder choice matters here.** `winnerID` is spelled with a capital `ID` (the normal Swift
/// convention for an acronym), but `.convertFromSnakeCase` turns `winner_id` into `winnerId`
/// (lowercase `d`) — not `winnerID` — so decoding this with `.supabase` would silently leave
/// `winnerID` `nil` on every single row, the same class of bug `SupabaseDecoderTests` pins for
/// `VersusChallenge`. This type carries its own snake_case `CodingKeys` and must be decoded with
/// `JSONDecoder.supabaseExplicitKeys`, never `.supabase` — see `VersusRepository.liveState`.
struct LiveDuelState: Decodable, Equatable {
    struct Side: Decodable, Equatable {
        let ready: Bool
        let guesses: Int
        let finished: Bool
        let solved: Bool
    }

    let liveStartedAt: Date?
    let serverNow: Date
    let timeLimitSeconds: Int
    /// `'pending' | 'completed' | 'forfeited'` — the same domain `VersusChallenge.status`
    /// already uses, because a live duel resolves onto the exact same row and column.
    let status: String
    let winnerID: String?
    let me: Side
    let them: Side

    enum CodingKeys: String, CodingKey {
        case liveStartedAt = "live_started_at"
        case serverNow = "server_now"
        case timeLimitSeconds = "time_limit_seconds"
        case status
        case winnerID = "winner_id"
        case me, them
    }

    var bothReady: Bool { me.ready && them.ready }
    /// When the shared clock runs out — nil until `live_started_at` is stamped, i.e. before
    /// both sides have readied up.
    var deadline: Date? { liveStartedAt.map { $0.addingTimeInterval(TimeInterval(timeLimitSeconds)) } }
}

/// The live-duel polling engine (M23). One instance per duel, created by `LiveDuelLobbyView` and
/// carried through onto the `DuelSession` that hands off to the game view (`DuelSession.live`),
/// so the same poll loop covers the ready handshake *and* the race — no restart, no gap where a
/// resolution could land unseen.
///
/// **Why this owns a `VersusRepository` directly.** Views in this app touch `RepositoryContainer`
/// only, never a repository — but this is not a view, and `RepositoryContainer` has no per-instance
/// lifecycle to hang a start/stop/cancel-on-disappear poll loop off of (it's a single
/// `@MainActor` object for the whole session). The view that creates one still only ever reads
/// `container.versus` to hand it in, same as every other Versus surface.
@MainActor
final class LiveDuelSession: ObservableObject {
    /// How often the board polls while open — M23 §2's budget (~80 requests/player/duel at
    /// `time_limit_seconds` 120). A longer interval is the sanctioned first lever if this ever
    /// needs to get cheaper; a websocket is explicitly not (AGENTS.md §11).
    static let pollInterval: TimeInterval = 1.5

    let challengeID: Int
    /// `puzzles.id` this duel points at — carried here (rather than left to the presenting view)
    /// so `loadPuzzle` can fetch it without a second dependency; mirrors why `DuelSession` itself
    /// carries `boardID` instead of leaving it to each game view to work out.
    private let puzzleID: String
    private let repository: VersusRepository

    /// The latest poll, or nil before the first one lands (still in the "opening the lobby"
    /// instant). `LiveJourneymanBoard` only mounts once `bothReady`, i.e. once a real poll has
    /// already landed, so in practice a duelable game view never actually sees `nil` here — but
    /// the type stays honest about the one instant (right after this object is constructed, in
    /// the lobby, before the first RPC round trip) where that's genuinely not yet known.
    @Published private(set) var state: LiveDuelState?
    /// True from the moment a poll fails until the next one succeeds — enough for a caller that
    /// wants a soft "reconnecting…" hint. Never load-bearing on its own: a dropped poll is not a
    /// forfeit, so nothing here ends the duel because of it.
    @Published private(set) var pollFailing = false

    private var pollTask: Task<Void, Never>?

    init(challengeID: Int, puzzleID: String, repository: VersusRepository) {
        self.challengeID = challengeID
        self.puzzleID = puzzleID
        self.repository = repository
    }

    // MARK: - Read

    var bothReady: Bool { state?.bothReady ?? false }
    var iAmReady: Bool { state?.me.ready ?? false }
    var opponentReady: Bool { state?.them.ready ?? false }
    var myGuesses: Int { state?.me.guesses ?? 0 }
    var opponentGuesses: Int { state?.them.guesses ?? 0 }
    var iAmFinished: Bool { state?.me.finished ?? false }
    var opponentFinished: Bool { state?.them.finished ?? false }
    var opponentSolved: Bool { state?.them.solved ?? false }
    /// The row has left `'pending'` — either someone won outright or the shared clock ran out
    /// with nobody solving. The poll loop stops itself here (see `poll()`); a caller's UI should
    /// treat this as "the race is over, render the verdict" rather than keep waiting. False
    /// (never "unknown") before the first poll — nothing has resolved if nothing has been asked.
    var isResolved: Bool { state.map { $0.status != "pending" } ?? false }
    /// The duel ended because the **opponent** solved it — distinct from `isResolved` alone,
    /// which is also true on a plain clock-expiry draw where nobody actually won. This is the
    /// game view's cue to close the local board with a loss even if the player still has
    /// guesses left; it can never be true from a wrong guess, because only a `solved` submit
    /// resolves the row early (M23 §1).
    var opponentAlreadyWon: Bool { isResolved && opponentSolved }
    /// The shared par time both sides are scored against (M25b) — `DuelSession.secondsRemaining`
    /// still needs an `Int` at hand-off, but nothing recomputes a live countdown from it any
    /// more (the race ends on `isResolved`, not on this reaching zero). Zero before the first
    /// poll lands, same as every other `state`-derived read here.
    var parSeconds: Int { state?.timeLimitSeconds ?? 0 }

    // MARK: - Lifecycle

    /// Idempotent — safe to call from a view's `.onAppear` *and* a `scenePhase` return to
    /// `.active` without stacking a second loop. Stops itself once the duel resolves; a caller
    /// only ever needs to call `stop()` for disappearance/backgrounding, not for a normal finish.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll()
                if Task.isCancelled || self.isResolved { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
            self.pollTask = nil
        }
    }

    /// Called on view disappearance and on backgrounding (M23 §2's liveness rule: a client that
    /// stops polling has backgrounded or died, and the server resolves the duel regardless — so
    /// this never needs to tell the server anything, it just stops spending requests).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        do {
            let fetched = try await repository.liveState(challengeID: challengeID)
            state = fetched
            pollFailing = false
        } catch is CancellationError {
            // The loop's own Task was cancelled mid-request (view went away) — not a network
            // blip, nothing to record.
        } catch {
            // A dropped poll is not a forfeit: keep the last good `state` and try again next
            // tick rather than tearing the duel down over one bad request.
            pollFailing = true
        }
    }

    // MARK: - Write

    /// Stamps my readiness and applies the RPC's own returned state immediately, so the lobby
    /// doesn't wait up to `pollInterval` to see its own tap register. Starts (or resumes) polling
    /// as a side effect — the one call site that both readies up and is guaranteed to run before
    /// any poll has, so it's also where the loop first gets kicked off.
    func ready() async throws {
        let fetched = try await repository.markReady(challengeID: challengeID)
        state = fetched
        start()
    }

    /// Relays a guess count without finishing, so the opponent's `OpponentProgressStrip` ticks
    /// up without waiting on this player's own next poll tick.
    func reportGuesses(_ guesses: Int) async {
        await repository.bumpGuesses(challengeID: challengeID, guesses: guesses)
    }

    /// Finishes my side (solved, exhausted guesses, or gave up) and polls once more immediately
    /// rather than waiting for the loop's own tick — a solve that ends the whole duel should see
    /// its own resolution (the opponent's final guess count, `winnerID`) without a visible lag.
    func submitResult(solved: Bool, guesses: Int) async {
        await repository.submitLiveResult(challengeID: challengeID, solved: solved, guesses: guesses)
        await poll()
    }

    /// Loads the exact board this duel points at. Generic over the content type, on purpose —
    /// this engine is format-agnostic (M23 ships Journeyman only; `PuzzleFormat.supportsLiveDuel`
    /// is the gate, not this method's signature), the same way `VersusRepository.puzzle` and
    /// `RepositoryContainer.startVersusBoard` already are for the async path.
    func loadPuzzle<T: Decodable>(_ type: T.Type) async -> T? {
        await repository.puzzle(type, id: puzzleID)
    }
}

extension LiveDuelSession: Equatable {
    /// Identity, not value, equality — `state` changes on every poll and comparing by content
    /// would make `DuelSession` (which embeds this) appear to change every 1.5s even when
    /// nothing about the duel itself did.
    static func == (lhs: LiveDuelSession, rhs: LiveDuelSession) -> Bool { lhs === rhs }
}
