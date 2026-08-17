import Foundation

enum VersusError: Error, Equatable {
    case opponentNotFound
    case cannotChallengeSelf
    /// The server had no archive puzzle left in that (sport, format) that neither player has
    /// already played. Real, not theoretical: tennis has 25 Keep4 boards total.
    case noUnplayedPuzzle
    /// `start_versus_challenge` refused — the duel resolved or expired between the tap and the
    /// call. Distinct from a network failure, because the right response is "refresh the list",
    /// not "retry".
    case duelClosed
}

/// `{ "content": … }`, the single-column projection every by-id puzzle fetch uses. File-scope
/// rather than nested inside `puzzle(_:id:)` — Swift can't nest a generic type in a generic
/// function.
private struct PuzzleContentEnvelope<C: Decodable>: Decodable { let content: C }

/// Reads/writes 1v1 duels + series. No local/offline mode — Versus is inherently
/// server-mediated (mirrors `CommunityPuzzleRepository`'s remote-only shape).
final class VersusRepository {
    private let client: SupabaseClient
    /// `VersusChallenge`/`VersusSeries` spell their columns out in explicit snake_case
    /// `CodingKeys`, so they must NOT go through `.supabase`'s `.convertFromSnakeCase` — see
    /// that decoder's doc comment for the outage this caused.
    private let rowDecoder: JSONDecoder = .supabaseExplicitKeys
    /// Puzzle `content` is camelCase jsonb, same as every other puzzle fetch in the app.
    private let contentDecoder = JSONDecoder()

    /// How many settled duels the RESULTS section shows. The fetch had no `limit` at all, which
    /// is unbounded growth on a list nobody scrolls past the first screen of.
    static let resultsPageSize = 30

    init(client: SupabaseClient) { self.client = client }

    /// Challenges (any status) where the caller is either side, newest first.
    private func myChallenges(userID: String, statuses: [String], limit: Int?) async -> [VersusChallenge] {
        let statusFilter = statuses.map { "\"\($0)\"" }.joined(separator: ",")
        var items = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "or", value: "(challenger_id.eq.\(userID),opponent_id.eq.\(userID))"),
            URLQueryItem(name: "status", value: "in.(\(statusFilter))"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ]
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return (try? await client.select("versus_challenges", query: items, decoder: rowDecoder)) ?? []
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

    /// Attaches each row's `versus_series` (win counts, completion status) via one batched
    /// `in.(…)` query on the distinct series ids — mirrors the `profiles` join above and
    /// `CohortRepository.standings`'s member/profile join. A series id absent from the result
    /// (RLS gap, or already-vanished row) just leaves that row's `series` nil.
    private func withSeries(_ rows: [VersusChallengeRow]) async -> [VersusChallengeRow] {
        guard !rows.isEmpty else { return [] }
        let ids = Set(rows.map { $0.challenge.seriesId }).map(String.init).joined(separator: ",")
        let series: [VersusSeries] = (try? await client.select("versus_series", query: [
            URLQueryItem(name: "select", value: "id,user_a,user_b,sport,format,wins_a,wins_b,status"),
            URLQueryItem(name: "id", value: "in.(\(ids))"),
        ], decoder: rowDecoder)) ?? []
        let seriesByID = Dictionary(uniqueKeysWithValues: series.map { ($0.id, $0) })
        return rows.map { row in
            var row = row
            row.series = seriesByID[row.challenge.seriesId]
            return row
        }
    }

    /// Open duels — `'pending'` only. `'active'` used to be in this filter but was never written
    /// by any RPC; the server now carries a check constraint that forbids it outright.
    func openChallenges(userID: String) async -> [VersusChallengeRow] {
        let rows = await withOpponentNames(await myChallenges(userID: userID, statuses: ["pending"],
                                                              limit: nil), me: userID)
        return await withSeries(rows)
    }

    func recentResults(userID: String) async -> [VersusChallengeRow] {
        let rows = await withOpponentNames(
            await myChallenges(userID: userID, statuses: ["completed", "forfeited"],
                               limit: Self.resultsPageSize), me: userID)
        return await withSeries(rows)
    }

    /// Resolves a username to a user id via the (world-readable) `profiles` table. Prefer
    /// `createChallenge(opponentID:…)` wherever the surface already holds an id — every entry
    /// point used to round-trip through a name, which is what made a duel impossible against
    /// anyone who hadn't claimed a username.
    func findOpponent(username: String) async -> String? {
        struct Row: Decodable { let id: String }
        let rows: [Row] = (try? await client.select("profiles", query: [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "username", value: "eq.\(username)"),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? []
        return rows.first?.id
    }

    /// Starts (or continues) a series against `opponentID` and returns the duel's id.
    ///
    /// The board is **not** passed in any more. `create_versus_challenge` picks it server-side
    /// from the released archive, excluding every puzzle either player has a `game_results` row
    /// for — a client that named its own puzzle could name the one it had just finished.
    /// The call is idempotent while a duel in the same series is still open.
    func createChallenge(opponentID: String, sport: Sport, format: PuzzleFormat,
                         timeLimit: Int? = nil) async throws -> Int {
        struct Args: Encodable {
            let pOpponent: String; let pSport: String; let pFormat: String; let pTimeLimit: Int
            enum CodingKeys: String, CodingKey {
                case pOpponent = "p_opponent", pSport = "p_sport"
                case pFormat = "p_format", pTimeLimit = "p_time_limit"
            }
        }
        let args = Args(pOpponent: opponentID, pSport: sport.rawValue, pFormat: format.rawValue,
                        pTimeLimit: timeLimit ?? format.defaultDuelSeconds)
        let data: Data
        do {
            data = try await client.rpc("create_versus_challenge", args: args)
        } catch {
            // The one server-side failure a player can actually hit and act on. Everything else
            // (auth, network, a malformed opponent id) is the generic path.
            throw String(describing: error).contains("no unplayed puzzle")
                ? VersusError.noUnplayedPuzzle : error
        }
        // PostgREST returns a scalar return value as a bare JSON number.
        if let n = try? JSONDecoder().decode(Int.self, from: data) { return n }
        throw VersusError.opponentNotFound
    }

    /// Starts *this player's* clock and returns the seconds they have left.
    ///
    /// Server-authoritative by construction: the server stamps `*_started_at` on the first call
    /// and computes the remainder itself, so the device never has to be trusted about what time
    /// it is, and re-opening after a crash resumes the same countdown instead of restarting it.
    func startChallenge(id: Int) async throws -> Int {
        struct Args: Encodable {
            let pChallengeId: Int
            enum CodingKeys: String, CodingKey { case pChallengeId = "p_challenge_id" }
        }
        let data: Data
        do {
            data = try await client.rpc("start_versus_challenge", args: Args(pChallengeId: id))
        } catch {
            throw String(describing: error).contains("duel is closed")
                ? VersusError.duelClosed : error
        }
        guard let seconds = try? JSONDecoder().decode(Int.self, from: data) else {
            throw VersusError.duelClosed
        }
        return seconds
    }

    /// Loads the exact puzzle a duel points at, whatever format it is.
    ///
    /// One generic fetch rather than a `keep4Puzzle(id:)` / `gridPuzzle(id:)` / `whoAmIPuzzle(id:)`
    /// trio (AGENTS.md §4): `puzzles.id` is unique across formats, so the id alone identifies the
    /// row and the only thing that varies is what `content` decodes as.
    ///
    ///     let board: GridPuzzle? = await versus.puzzle(GridPuzzle.self, id: challenge.puzzleId)
    func puzzle<T: Decodable>(_ type: T.Type, id: String) async -> T? {
        let rows: [PuzzleContentEnvelope<T>]? = try? await client.select("puzzles", query: [
            URLQueryItem(name: "select", value: "content"),
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "limit", value: "1"),
        ], decoder: contentDecoder)
        return rows?.first?.content
    }

    /// Records the caller's score via the `submit_versus_result` RPC. The server clamps the
    /// value to 0...1, validates it against the clock it started, and takes the first write only.
    func submitResult(challengeID: Int, score: Double) async {
        struct Args: Encodable { let pChallengeId: Int; let pScore: Double
            enum CodingKeys: String, CodingKey { case pChallengeId = "p_challenge_id", pScore = "p_score" }
        }
        try? await client.rpc("submit_versus_result", args: Args(pChallengeId: challengeID, pScore: score))
    }
}
