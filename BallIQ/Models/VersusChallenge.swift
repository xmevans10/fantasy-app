import Foundation

/// A single duel within a head-to-head series — both sides play the same puzzle independently,
/// each against their own clock, then the results are compared. Mirrors `versus_challenges`.
///
/// The board is **not** "today's daily" any more. `create_versus_challenge` picks it server-side
/// from the released archive, excluding anything either player has a `game_results` row for —
/// which closes the pre-play exploit (finish your daily, learn the answers, then challenge and
/// replay with perfect knowledge) and is also what frees a duel from being tied to a calendar day.
struct VersusChallenge: Decodable, Identifiable, Equatable {
    let id: Int
    let seriesId: Int
    let sport: Sport
    /// Which game this duel is played in. Added 2026-08-13 — before it, `versus_series`'
    /// uniqueness index was `(user_a, user_b, sport)`, so a Grid duel between two players who
    /// already had a Keep4 series in the same sport silently collided with it.
    let format: PuzzleFormat
    let puzzleId: String
    let challengerId: String
    let opponentId: String
    /// `"pending" | "completed" | "forfeited"`. `'active'` was removed: it was declared here and
    /// branched on in two places but written by no RPC, ever, and `versus-timeout` sweeps only
    /// `'pending'` — so any row that did land in it would have hung open forever. The server now
    /// carries a check constraint on this domain.
    let status: String
    let challengerScore: Double?
    let opponentScore: Double?
    let winnerId: String?
    /// Per-side seconds on the clock, set at creation. Each player's own countdown starts when
    /// *they* open the board (`start_versus_challenge`), which is what makes an asynchronously
    /// scheduled duel feel synchronous.
    let timeLimitSeconds: Int
    let challengerStartedAt: Date?
    let opponentStartedAt: Date?
    let createdAt: Date
    let expiresAt: Date
    /// `"async" | "live"` (M23). Added alongside the live-duel columns — defaults to `"async"`
    /// so a row cached before that migration (`DiskCache` has no schema version) still decodes
    /// as the mode it was actually played in, rather than throwing and emptying the tab.
    let mode: String

    enum CodingKeys: String, CodingKey {
        case id, sport, status, format, mode
        case seriesId = "series_id"
        case puzzleId = "puzzle_id"
        case challengerId = "challenger_id"
        case opponentId = "opponent_id"
        case challengerScore = "challenger_score"
        case opponentScore = "opponent_score"
        case winnerId = "winner_id"
        case timeLimitSeconds = "time_limit_seconds"
        case challengerStartedAt = "challenger_started_at"
        case opponentStartedAt = "opponent_started_at"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    /// Hand-written rather than synthesized so the three columns added in 2026-08-13's migration
    /// decode as their defaults against a *cached* row fetched before the migration landed —
    /// `DiskCache` has no schema version, and a thrown error here would empty the Versus tab.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        seriesId = try c.decode(Int.self, forKey: .seriesId)
        sport = try c.decode(Sport.self, forKey: .sport)
        format = try c.decodeIfPresent(PuzzleFormat.self, forKey: .format) ?? .keep4
        puzzleId = try c.decode(String.self, forKey: .puzzleId)
        challengerId = try c.decode(String.self, forKey: .challengerId)
        opponentId = try c.decode(String.self, forKey: .opponentId)
        status = try c.decode(String.self, forKey: .status)
        challengerScore = try c.decodeIfPresent(Double.self, forKey: .challengerScore)
        opponentScore = try c.decodeIfPresent(Double.self, forKey: .opponentScore)
        winnerId = try c.decodeIfPresent(String.self, forKey: .winnerId)
        timeLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .timeLimitSeconds)
            ?? (try c.decodeIfPresent(PuzzleFormat.self, forKey: .format) ?? .keep4).defaultDuelSeconds
        challengerStartedAt = try c.decodeIfPresent(Date.self, forKey: .challengerStartedAt)
        opponentStartedAt = try c.decodeIfPresent(Date.self, forKey: .opponentStartedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "async"
    }

    /// Memberwise init for tests and previews — `init(from:)` above suppresses the synthesized one.
    init(id: Int, seriesId: Int, sport: Sport, format: PuzzleFormat = .keep4, puzzleId: String,
         challengerId: String, opponentId: String, status: String,
         challengerScore: Double? = nil, opponentScore: Double? = nil, winnerId: String? = nil,
         timeLimitSeconds: Int = 120, challengerStartedAt: Date? = nil,
         opponentStartedAt: Date? = nil, createdAt: Date = Date(),
         expiresAt: Date = Date().addingTimeInterval(86_400), mode: String = "async") {
        self.id = id
        self.seriesId = seriesId
        self.sport = sport
        self.format = format
        self.puzzleId = puzzleId
        self.challengerId = challengerId
        self.opponentId = opponentId
        self.status = status
        self.challengerScore = challengerScore
        self.opponentScore = opponentScore
        self.winnerId = winnerId
        self.timeLimitSeconds = timeLimitSeconds
        self.challengerStartedAt = challengerStartedAt
        self.opponentStartedAt = opponentStartedAt
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.mode = mode
    }

    /// Whether this duel races live rather than playing async — the row-level fact that backs
    /// `PuzzleFormat.supportsLiveDuel`'s client-side gate. Kept as its own check (not folded into
    /// `format.supportsLiveDuel`) so a pre-milestone pending Journeyman row — created before
    /// `create_versus_challenge` learned to stamp `mode = 'live'` — still plays the async path it
    /// was actually created for instead of being routed into a lobby with no ready state to poll.
    var isLive: Bool { mode == "live" }

    func opponentID(me: String) -> String { challengerId == me ? opponentId : challengerId }
    func myScore(me: String) -> Double? { challengerId == me ? challengerScore : opponentScore }
    func theirScore(me: String) -> Double? { challengerId == me ? opponentScore : challengerScore }
    func hasPlayed(me: String) -> Bool { myScore(me: me) != nil }

    /// Whether I won — nil when the duel isn't decided *or* when it was a draw.
    ///
    /// A draw is now a real outcome: `resolve_versus_challenge` breaks a score tie on elapsed
    /// time, and only a dead heat on *both* leaves `winner_id` null on a `completed` row. Use
    /// `isDraw` to tell that apart from "not finished yet"; `'forfeited'` remains reserved for
    /// the double no-show.
    func won(me: String) -> Bool? { winnerId == nil ? nil : winnerId == me }

    /// A settled duel that nobody won: identical scores *and* identical elapsed time.
    var isDraw: Bool { status == "completed" && winnerId == nil }

    /// Whether this player has opened the board and started their clock. Both sides' clocks run
    /// independently, so this is a per-player question.
    func hasStarted(me: String) -> Bool {
        (challengerId == me ? challengerStartedAt : opponentStartedAt) != nil
    }
}

/// A `versus_challenge` plus the opponent's display name and its parent series, ready for the
/// Versus tab list. `series` is nil when the batch series fetch didn't return a match (RLS gap,
/// or the row was fetched before the series existed) — callers must not force-unwrap it.
struct VersusChallengeRow: Identifiable, Equatable {
    let challenge: VersusChallenge
    let opponentUsername: String?
    var series: VersusSeries? = nil
    var id: Int { challenge.id }

    /// Open challenges where I haven't played yet — fuel for the Versus tab badge. The status
    /// check is redundant against `openChallenges`'s server-side filter but keeps this safe to
    /// call directly against an unfiltered/mixed list (as the unit tests do).
    static func unplayedCount(_ rows: [VersusChallengeRow], me: String) -> Int {
        rows.filter { $0.challenge.status == "pending" && !$0.challenge.hasPlayed(me: me) }.count
    }
}

struct VersusSeries: Decodable, Equatable {
    let id: Int
    let userA: String
    let userB: String
    let sport: Sport
    let format: PuzzleFormat
    let winsA: Int
    let winsB: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, sport, status, format
        case userA = "user_a"
        case userB = "user_b"
        case winsA = "wins_a"
        case winsB = "wins_b"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        userA = try c.decode(String.self, forKey: .userA)
        userB = try c.decode(String.self, forKey: .userB)
        sport = try c.decode(Sport.self, forKey: .sport)
        format = try c.decodeIfPresent(PuzzleFormat.self, forKey: .format) ?? .keep4
        winsA = try c.decode(Int.self, forKey: .winsA)
        winsB = try c.decode(Int.self, forKey: .winsB)
        status = try c.decode(String.self, forKey: .status)
    }

    init(id: Int, userA: String, userB: String, sport: Sport, format: PuzzleFormat = .keep4,
         winsA: Int, winsB: Int, status: String) {
        self.id = id
        self.userA = userA
        self.userB = userB
        self.sport = sport
        self.format = format
        self.winsA = winsA
        self.winsB = winsB
        self.status = status
    }

    func myWins(me: String) -> Int { me == userA ? winsA : winsB }
    func theirWins(me: String) -> Int { me == userA ? winsB : winsA }

    /// Wins needed to take the series. First to 4 — a 4-0 lead used to grind three dead rubbers
    /// because the series only completed at 7 *played*.
    static let winTarget = 4
}
