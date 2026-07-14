import Foundation

/// Remote half of the arcade weekly boards (`arcade_scores` in Supabase): posts a finished
/// run's score and reads the ranked board for one game+sport. Remote-only like
/// `DailyDraftLeaderboardRepository`; local high scores (`LocalOverUnderStore`) stay the
/// offline story. Unlike Daily Draft there's no resubmit-on-sign-in queue: a run that
/// fails to post is a low-stakes loss — the next good run this week reposts — and the
/// board ranks each user's weekly best server-side, so duplicate posts are harmless.
final class ArcadeLeaderboardRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    /// Which arcade format a score belongs to — raw values match the table's `game` check.
    enum Game: String {
        case overUnder = "over_under"
        case grid = "grid"

        /// Board sheet title, matching each game's own in-app label.
        var displayName: String {
            switch self {
            case .overUnder: return "Over / Under"
            case .grid: return "Grid"
            }
        }
    }

    /// One row of `arcade_leaderboard(p_game, p_sport)`: top-50 for the current UTC week
    /// plus the caller's own row (with its true rank) even when outside the top 50.
    struct Row: Decodable, Identifiable, Equatable {
        let rank: Int
        let userId: String
        let username: String?
        let avatar: String?
        let bestScore: Int
        let isMe: Bool
        var id: String { userId }

        enum CodingKeys: String, CodingKey {
            case rank, username, avatar
            case userId = "user_id"
            case bestScore = "best_score"
            case isMe = "is_me"
        }

        var displayName: String { username ?? "Player" }
    }

    /// Posts one finished run. `week_start` is server-computed (column default; the insert
    /// policy rejects anything else), so the row only carries who/what/how many.
    func submit(userID: String, game: Game, sport: Sport, score: Int) async {
        struct NewScore: Encodable {
            let user_id: String
            let game: String
            let sport: String
            let score: Int
        }
        try? await client.insert("arcade_scores", values: NewScore(
            user_id: userID, game: game.rawValue, sport: sport.rawValue, score: score))
    }

    /// Current UTC week's board for one game+sport.
    func leaderboard(game: Game, sport: Sport) async -> [Row] {
        struct Args: Encodable {
            let p_game: String
            let p_sport: String
        }
        guard let data = try? await client.rpc(
                "arcade_leaderboard", args: Args(p_game: game.rawValue, p_sport: sport.rawValue)),
              let rows: [Row] = try? client.decode(data) else { return [] }
        return rows
    }
}
