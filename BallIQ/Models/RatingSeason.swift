import Foundation

/// One 8-week competitive rating cycle (roadmap v1.4 / M5 Phase F). Distinct from the weekly
/// `Season`/cohort ladder in `Cohort.swift`: this is the *rating* ladder. The all-time rating
/// stays permanent; each rating season is a fresh parallel ladder seeded from a soft-reset
/// snapshot, so a server reset never fights the client's `max`-merge on the all-time value.
struct RatingSeason: Decodable, Equatable, Identifiable {
    // Property names are camelCase so `JSONDecoder.supabase`'s `.convertFromSnakeCase` maps the
    // `starts_at`/`ends_at` columns automatically — do NOT add explicit snake_case CodingKeys, which
    // the key-conversion strategy would then fail to find (see the `.convertFromSnakeCase` note there).
    let id: Int
    let startsAt: Date
    let endsAt: Date
    let status: String
}

/// Pure soft-reset seed math: where a player *starts* a new season's rating, based on their
/// established all-time skill. Halves the distance from the 1000 baseline so strong players keep
/// a head start without the ladder being pre-decided. Clamped ≥ 0 like `RatingEngine.apply`.
enum SeasonSeed {
    static func seed(fromAllTime allTime: Int) -> Int {
        let base = RatingEngine.startingRating
        return max(0, base + Int((Double(allTime - base) * 0.5).rounded()))
    }
}

/// A player's end-of-season cosmetic reward: the peak tier reached that season. Written by the
/// `rating-season-rollover` Edge Function when a season closes; shown on Profile.
struct SeasonBadge: Decodable, Equatable, Identifiable {
    let seasonId: Int
    let sport: String
    let peakTier: String
    let peakRating: Int
    let createdAt: Date

    var id: String { "\(seasonId).\(sport)" }
    var tier: Tier { Tier(rawValue: peakTier) ?? .bronze }
}

/// One row of `season_leaderboard(p_sport)`: top-50 for the active season plus the caller's own
/// row (true rank) even outside the top 50 — mirrors `ArcadeLeaderboardRepository.Row`.
struct SeasonStandingRow: Decodable, Identifiable, Equatable {
    let rank: Int
    let userId: String
    let username: String?
    let avatar: String?
    let rating: Int
    let peakRating: Int
    let isMe: Bool
    var id: String { userId }

    var displayName: String { username ?? "Player" }
    var tier: Tier { Tier.forRating(rating) }
}

/// Pure countdown/label math for the rating season, kept out of the view so the SEASON hero, the
/// countdown card, and any "how seasons work" copy all read one source (mirrors `LeagueRules`).
enum RatingSeasonRules {
    static let cycleWeeks = 8

    /// Days/hours remaining until `end`, as a compact "Nd Nh" / "Nh Nm" string — an 8-week span
    /// wants coarse units, not seconds (reuses the phrasing of `LeaguesView.countdownText`).
    static func remainingText(now: Date, end: Date) -> String {
        let secs = max(0, Int(end.timeIntervalSince(now)))
        let days = secs / 86_400
        let hours = (secs % 86_400) / 3_600
        let minutes = (secs % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Reads rating-season state (the active season, its board, a player's badges). Remote-only,
/// like `CohortRepository` — the rating ladder is inherently server-defined.
final class SeasonRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    /// The active season, via the `current_rating_season()` RPC. Nil offline / between seasons.
    func current() async -> RatingSeason? {
        struct Args: Encodable {}
        guard let data = try? await client.rpc("current_rating_season", args: Args()),
              let rows: [RatingSeason] = try? client.decode(data) else { return nil }
        return rows.first
    }

    /// Active-season board for one sport (top-50 + caller's own row).
    func leaderboard(sport: Sport) async -> [SeasonStandingRow] {
        struct Args: Encodable { let p_sport: String }
        guard let data = try? await client.rpc(
                "season_leaderboard", args: Args(p_sport: sport.rawValue)),
              let rows: [SeasonStandingRow] = try? client.decode(data) else { return [] }
        return rows
    }

    /// A user's earned season badges, newest first (world-readable, so works for public profiles too).
    func badges(userID: String) async -> [SeasonBadge] {
        let items = [
            URLQueryItem(name: "select", value: "season_id,sport,peak_tier,peak_rating,created_at"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ]
        return (try? await client.select("season_badges", query: items)) ?? []
    }
}
