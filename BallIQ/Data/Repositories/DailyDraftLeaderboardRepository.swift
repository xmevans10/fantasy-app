import Foundation

/// Remote half of the Daily Draft loop (`daily_draft_scores` in Supabase): submits the
/// day's official score and reads the ranked board. Remote-only like `CohortRepository` —
/// the offline story is `DailyDraftStore`, which keeps the official run locally and lets
/// `RepositoryContainer` retry the submit on a later launch (the server RPC is
/// first-write-wins, so retries and replays can never overwrite an earlier submit).
final class DailyDraftLeaderboardRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    /// One row of `daily_draft_leaderboard(p_day)`: top-50 plus the caller's own row
    /// (with its true rank) even when they're outside the top 50.
    struct Row: Decodable, Identifiable, Equatable {
        let rank: Int
        let userId: String
        let username: String?
        let avatar: String?
        let sport: Sport
        let wins: Int
        let losses: Int
        let totalPoints: Int
        let outcome: String
        let isMe: Bool
        var id: String { userId }

        enum CodingKeys: String, CodingKey {
            case rank, username, avatar, sport, wins, losses, outcome
            case userId = "user_id"
            case totalPoints = "total_points"
            case isMe = "is_me"
        }

        var displayName: String { username ?? "Player" }
    }

    /// Pushes `result` as the caller's official score for `day` ("YYYY-MM-DD", UTC — the
    /// same `OverUnderRoundGenerator.dayString` key `DailyDraftStore` uses). Returns whether
    /// the server accepted it as the day's official score; `false` means one was already
    /// recorded (a retry after an earlier successful submit — fine, not an error).
    @discardableResult
    func submit(day: String, stored: DailyDraftStore.StoredResult) async -> Bool {
        struct Args: Encodable {
            let p_day: String
            let p_sport: String
            let p_wins: Int
            let p_losses: Int
            let p_total_points: Int
            let p_outcome: String
        }
        let args = Args(p_day: day, p_sport: stored.sport, p_wins: stored.wins,
                        p_losses: stored.losses, p_total_points: stored.totalPoints,
                        p_outcome: stored.outcome)
        guard let data = try? await client.rpc("submit_daily_draft_score", args: args) else {
            return false
        }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    func leaderboard(day: String) async -> [Row] {
        struct Args: Encodable { let p_day: String }
        guard let data = try? await client.rpc("daily_draft_leaderboard", args: Args(p_day: day)),
              let rows: [Row] = try? client.decode(data) else { return [] }
        return rows
    }
}
