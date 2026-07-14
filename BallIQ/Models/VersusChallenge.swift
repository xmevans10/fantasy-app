import Foundation

/// A single challenge within a head-to-head series — both sides play the same daily Keep4 puzzle
/// independently, then results are compared. Mirrors `versus_challenges`.
struct VersusChallenge: Decodable, Identifiable, Equatable {
    let id: Int
    let seriesId: Int
    let sport: Sport
    let puzzleId: String
    let challengerId: String
    let opponentId: String
    let status: String   // "pending" | "active" | "completed" | "forfeited"
    let challengerScore: Double?
    let opponentScore: Double?
    let winnerId: String?
    let createdAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, sport, status
        case seriesId = "series_id"
        case puzzleId = "puzzle_id"
        case challengerId = "challenger_id"
        case opponentId = "opponent_id"
        case challengerScore = "challenger_score"
        case opponentScore = "opponent_score"
        case winnerId = "winner_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    func opponentID(me: String) -> String { challengerId == me ? opponentId : challengerId }
    func myScore(me: String) -> Double? { challengerId == me ? challengerScore : opponentScore }
    func theirScore(me: String) -> Double? { challengerId == me ? opponentScore : challengerScore }
    func hasPlayed(me: String) -> Bool { myScore(me: me) != nil }
    func won(me: String) -> Bool? { winnerId == nil ? nil : winnerId == me }
}

/// A `versus_challenge` plus the opponent's display name and its parent series, ready for the
/// Versus tab list. `series` is nil when the batch series fetch didn't return a match (RLS gap,
/// or the row was fetched before the series existed) — callers must not force-unwrap it.
struct VersusChallengeRow: Identifiable, Equatable {
    let challenge: VersusChallenge
    let opponentUsername: String?
    var series: VersusSeries? = nil
    var id: Int { challenge.id }

    /// Open (pending/active) challenges where I haven't played yet — fuel for the Versus tab
    /// badge (§ M20, the stopgap while APNs pushes for `versus_challenge` are stubbed). The
    /// status check is redundant against `pendingAndActive`'s server-side filter but keeps this
    /// safe to call directly against an unfiltered/mixed list (as the unit tests do).
    static func unplayedCount(_ rows: [VersusChallengeRow], me: String) -> Int {
        rows.filter { row in
            (row.challenge.status == "pending" || row.challenge.status == "active")
                && !row.challenge.hasPlayed(me: me)
        }.count
    }
}

struct VersusSeries: Decodable, Equatable {
    let id: Int
    let userA: String
    let userB: String
    let sport: Sport
    let winsA: Int
    let winsB: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, sport, status
        case userA = "user_a"
        case userB = "user_b"
        case winsA = "wins_a"
        case winsB = "wins_b"
    }

    func myWins(me: String) -> Int { me == userA ? winsA : winsB }
    func theirWins(me: String) -> Int { me == userA ? winsB : winsA }
}
