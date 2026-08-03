import Foundation

/// One finished session, recorded in full.
///
/// **Why this type exists.** Until it did, the app threw away nearly everything about a game the
/// moment it ended. `RepositoryContainer.complete(...)` receives `performance` and `perfect`,
/// feeds them to the Elo engine, and discards both; the raw score (`Keep4Scoring.Result.total`,
/// Who Am I?'s total, the Grid's cell/star tally) never even reached it. Per-question correctness
/// was computed for the result screen and died with the view. The only per-attempt record anywhere
/// was `ratingHistory.<sport>` — a `{date, rating}` pair with no format, score, or accuracy — which
/// is why "GAMES" on the Stats screen is literally `history.count`.
///
/// So every interesting question about a player's own history ("what's my best Grid ever?", "am I
/// better at NFL or NBA?", "which player do I keep cutting?") was unanswerable, not because the
/// data was hard to compute but because nobody wrote it down. This is the writing-it-down.
///
/// Immutable by construction, and `id` is client-generated so the server mirror can be an
/// idempotent `on conflict do nothing` — an offline backfill that retries can't double-count.
struct GameResult: Codable, Equatable, Identifiable {
    let id: UUID
    let playedAt: Date
    let format: GameFormatKind
    let sport: Sport
    let mode: PlayMode
    let ranked: Bool
    let perfect: Bool

    /// 0...1, the same value the Elo engine consumes. Kept because it's the one quality measure
    /// every format already agrees on, even the ones with no accuracy concept (Draft & Spin maps
    /// its outcome onto it).
    let performance: Double

    /// Raw format score and the maximum that session could have produced. `maxScore == 0` means
    /// "open-ended" (Over/Under, Draft & Spin), so a reader must not treat score/maxScore as a
    /// ratio without checking.
    let score: Int
    let maxScore: Int

    /// The universal accuracy pair, and the single highest-value field here: it's what lets one
    /// "career accuracy" number mean the same thing across six formats that otherwise share
    /// nothing. `attempted == 0` is legitimate (Draft & Spin has no right answers) — always read
    /// through `accuracy`, never divide directly.
    let correct: Int
    let attempted: Int

    /// Wall-clock session length. Optional because no format captured timing before this type
    /// existed, so early rows legitimately have none.
    let durationMs: Int?

    let ratingBefore: Int
    let ratingAfter: Int
    let xpEarned: Int
    let streakAfter: Int
    let puzzleID: String
    let details: GameResultDetails

    var ratingDelta: Int { ratingAfter - ratingBefore }

    /// Nil rather than 0 when nothing was attempted — a Draft & Spin row is not "0% accurate",
    /// it has no accuracy, and averaging those two things together would be wrong.
    var accuracy: Double? { attempted > 0 ? Double(correct) / Double(attempted) : nil }

    init(id: UUID = UUID(), playedAt: Date, format: GameFormatKind, sport: Sport, mode: PlayMode,
         ranked: Bool, perfect: Bool, performance: Double, score: Int, maxScore: Int,
         correct: Int, attempted: Int, durationMs: Int?, ratingBefore: Int, ratingAfter: Int,
         xpEarned: Int, streakAfter: Int, puzzleID: String, details: GameResultDetails) {
        self.id = id
        self.playedAt = playedAt
        self.format = format
        self.sport = sport
        self.mode = mode
        self.ranked = ranked
        self.perfect = perfect
        self.performance = performance
        self.score = score
        self.maxScore = maxScore
        self.correct = correct
        self.attempted = attempted
        self.durationMs = durationMs
        self.ratingBefore = ratingBefore
        self.ratingAfter = ratingAfter
        self.xpEarned = xpEarned
        self.streakAfter = streakAfter
        self.puzzleID = puzzleID
        self.details = details
    }
}

/// What *kind* of session this was — the dimension `GameFormatKind` can't express.
///
/// Needed because three different things all arrive as `.keep4Normal`: a daily, a community
/// puzzle, and a Versus leg. Likewise Daily Draft is a mode of `.draftSpin`, and the Grid has a
/// practice mode that's re-rollable on demand. Without this, "my best Grid ever" would happily
/// return a practice board the player re-rolled forty times until it was easy.
enum PlayMode: String, Codable, CaseIterable {
    case daily, practice, community, versus, dailyDraft, archive

    /// Whether a session may set a personal best. Practice is infinitely re-rollable and community
    /// puzzles are user-authored (and can be trivially easy), so both are excluded from records
    /// while still counting toward volume and accuracy stats.
    var countsForRecords: Bool { self != .practice && self != .community }
}

/// Per-format extras.
///
/// Deliberately a **flat struct of optionals** rather than an enum with associated values, for
/// three reasons that all bite in practice: it round-trips to a `jsonb` column without needing a
/// discriminator field; every addition is backward-compatible, so an older build decodes a row
/// written by a newer one instead of throwing; and a reader that wants one field ("most-missed
/// player") reaches for it directly instead of switching over six cases to get at one of them.
///
/// Names are denormalized alongside ids on purpose — "your most-missed player is Jordan Addison"
/// must not require a catalog fetch (or fail silently when that player has aged out of it).
struct GameResultDetails: Codable, Equatable {
    // MARK: Keep4 / Cut4
    var missedPlayerIDs: [String]?
    var missedPlayerNames: [String]?
    /// Kept someone who should have been cut.
    var missedKeepCount: Int?
    /// Cut someone who should have been kept.
    var missedCutCount: Int?
    var theme: String?

    // MARK: Who Am I?
    var cluesUsed: Int?
    var wrongGuesses: Int?
    var solved: Bool?
    var answerName: String?

    // MARK: Over / Under
    var bestCombo: Int?
    var livesLeft: Int?
    var overPicks: Int?
    var overCorrect: Int?
    var underPicks: Int?
    var underCorrect: Int?

    // MARK: The Grid
    var cellsSolved: Int?
    var rarityStars: Int?
    /// The axis labels of cells left unsolved, e.g. ["LAL", "30+ PPG season"] — powers the
    /// "nemesis category" stat without needing `grid_guesses`, which is write-only (no select
    /// policy) and therefore unreadable by the client.
    var missedCellHeaders: [String]?

    // MARK: Draft & Spin
    var outcome: String?
    var wins: Int?
    var losses: Int?
    var totalPoints: Int?
    var draftedPlayerNames: [String]?

    // MARK: Versus
    var opponentUserID: String?

    init() {}
}
