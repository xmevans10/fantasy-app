import Foundation

enum VersusError: Error { case opponentNotFound, cannotChallengeSelf }

/// Reads/writes 1v1 challenges + series. No local/offline mode — Versus is inherently
/// server-mediated (mirrors `CommunityPuzzleRepository`'s remote-only shape).
final class VersusRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    /// Challenges (any status) where the caller is either side, newest first.
    private func myChallenges(userID: String, statuses: [String]) async -> [VersusChallenge] {
        let statusFilter = statuses.map { "\"\($0)\"" }.joined(separator: ",")
        let items = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "or", value: "(challenger_id.eq.\(userID),opponent_id.eq.\(userID))"),
            URLQueryItem(name: "status", value: "in.(\(statusFilter))"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ]
        return (try? await client.select("versus_challenges", query: items)) ?? []
    }

    private func withOpponentNames(_ challenges: [VersusChallenge], me: String) async -> [VersusChallengeRow] {
        guard !challenges.isEmpty else { return [] }
        let ids = Set(challenges.map { $0.opponentID(me: me) }).joined(separator: ",")
        struct ProfileRow: Decodable { let id: String; let username: String? }
        let profiles: [ProfileRow] = (try? await client.select("profiles", query: [
            URLQueryItem(name: "select", value: "id,username"),
            URLQueryItem(name: "id", value: "in.(\(ids))"),
        ])) ?? []
        let nameByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.username) })
        return challenges.map { VersusChallengeRow(challenge: $0, opponentUsername: nameByID[$0.opponentID(me: me)] ?? nil) }
    }

    func pendingAndActive(userID: String) async -> [VersusChallengeRow] {
        await withOpponentNames(await myChallenges(userID: userID, statuses: ["pending", "active"]), me: userID)
    }

    func recentResults(userID: String) async -> [VersusChallengeRow] {
        await withOpponentNames(await myChallenges(userID: userID, statuses: ["completed", "forfeited"]), me: userID)
    }

    /// Resolves a username to a user id via the (now world-readable) `profiles` table.
    func findOpponent(username: String) async -> String? {
        struct Row: Decodable { let id: String }
        let rows: [Row] = (try? await client.select("profiles", query: [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "username", value: "eq.\(username)"),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? []
        return rows.first?.id
    }

    /// Starts (or continues) a series against `opponentID` on today's puzzle for `sport`.
    /// Returns the new challenge id.
    func createChallenge(opponentID: String, sport: Sport, puzzleID: String) async throws -> Int {
        struct Args: Encodable { let pOpponent: String; let pSport: String; let pPuzzleId: String
            enum CodingKeys: String, CodingKey { case pOpponent = "p_opponent", pSport = "p_sport", pPuzzleId = "p_puzzle_id" }
        }
        let data = try await client.rpc("create_versus_challenge",
            args: Args(pOpponent: opponentID, pSport: sport.rawValue, pPuzzleId: puzzleID))
        struct IDOnly: Decodable { let value: Int }
        // PostgREST returns the scalar return value as a bare JSON number.
        if let n = try? JSONDecoder().decode(Int.self, from: data) { return n }
        throw VersusError.opponentNotFound
    }

    /// Loads the exact puzzle a challenge points at (not "today's" pick — the challenge may be
    /// from a prior day, inside its 24h window).
    func keep4Puzzle(id: String) async -> Keep4Puzzle? {
        struct ContentRow: Decodable { let content: Keep4Puzzle }
        let rows: [ContentRow]? = try? await client.select("puzzles", query: [
            URLQueryItem(name: "select", value: "content"),
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "limit", value: "1"),
        ], decoder: JSONDecoder())
        return rows?.first?.content
    }

    /// Records the caller's score on a challenge via the `submit_versus_result` RPC.
    func submitResult(challengeID: Int, score: Double) async {
        struct Args: Encodable { let pChallengeId: Int; let pScore: Double
            enum CodingKeys: String, CodingKey { case pChallengeId = "p_challenge_id", pScore = "p_score" }
        }
        try? await client.rpc("submit_versus_result", args: Args(pChallengeId: challengeID, pScore: score))
    }
}
