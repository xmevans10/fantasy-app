import Foundation

/// A community puzzle as shown in the feed (no `content` — that's loaded on play).
struct CommunitySummary: Identifiable, Decodable, Equatable {
    let id: String
    let authorId: String
    let sport: Sport
    let format: String        // "keep4" | "whoami"
    let title: String
    let playCount: Int
    let createdAt: String
    /// Author's note (`content.description`), keep4 only — nil for whoami or when unset.
    let description: String?
    /// Baked grading kind (`content.scoring`: "ppr" | "era" | "custom"), keep4 only — nil for
    /// whoami and for legacy rows published before the field existed.
    let scoring: String?
    /// Baked grain (`content.grain`: "season" | "game" | "career"), keep4 only — nil for
    /// whoami and for legacy rows published before the field existed (every pre-single-game-
    /// creation community puzzle is season-grain regardless, since that was the only grain
    /// Create offered until then).
    let grain: String?
    /// Only selected by the moderation review queue ("public" | "unlisted" | "hidden");
    /// nil in the regular feed, which doesn't fetch it.
    let visibility: String?

    enum CodingKeys: String, CodingKey {
        case id, sport, format, title, description, scoring, grain, visibility
        case authorId = "author_id"
        case playCount = "play_count"
        case createdAt = "created_at"
    }

    /// Grading badge for the feed card. Legacy rows (nil) were created when only the fantasy
    /// presets were on the surface, so they default to `.ppr`.
    var scoringKind: ScoringKind { scoring.flatMap(ScoringKind.init(rawValue:)) ?? .ppr }

    /// Grain badge for the feed card. Legacy/nil rows default to `.season`.
    var grainKind: PuzzleGrain { grain.flatMap(PuzzleGrain.init(rawValue:)) ?? .season }
}

enum CommunitySort { case recent, popular, week }

/// Decodes just the `content` jsonb column of a community puzzle row.
private struct CommunityContentRow<C: Decodable>: Decodable { let content: C }

/// Reads + authenticated writes for user-generated puzzles (`community_puzzles`).
/// Writes rely on the user JWT already attached by `SupabaseClient`; RLS enforces
/// `auth.uid() = author_id`. Mirrors the `RemoteSync` insert pattern.
final class CommunityPuzzleRepository {
    private let client: SupabaseClient
    /// `content` jsonb stores camelCase JSON the Codable models decode directly.
    private let contentDecoder = JSONDecoder()
    private let summaryDecoder = JSONDecoder()   // CommunitySummary has explicit snake_case keys

    init(client: SupabaseClient) { self.client = client }

    // MARK: - Reads

    /// Throws on fetch failure (rather than returning `[]`) so callers can keep their last good
    /// list instead of blanking the feed on a transient error. See `CommunityView.merge`.
    func feed(format: String, sport: Sport?, sort: CommunitySort,
              authorId: String? = nil, limit: Int = 50) async throws -> [CommunitySummary] {
        var items = [
            URLQueryItem(name: "select",
                         value: "id,author_id,sport,format,title,play_count,created_at,description:content->>description,scoring:content->>scoring,grain:content->>grain"),
            URLQueryItem(name: "format", value: "eq.\(format)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let authorId {
            items.append(URLQueryItem(name: "author_id", value: "eq.\(authorId)"))
        } else {
            items.append(URLQueryItem(name: "visibility", value: "eq.public"))
        }
        if let sport { items.append(URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)")) }
        // .week fetches in recent order; the caller reorders via CommunityTrending +
        // weeklyPlayCounts() (and keeps recent order if that RPC isn't available).
        let order = sort == .popular ? "play_count.desc" : "created_at.desc"
        items.append(URLQueryItem(name: "order", value: order))

        return try await client.select("community_puzzles", query: items, decoder: summaryDecoder)
    }

    func keep4(id: String) async -> Keep4Puzzle? { await resolve(id: id) }
    func whoAmI(id: String) async -> WhoAmIPuzzle? { await resolve(id: id) }

    /// Usernames for a set of author ids via the world-readable `profiles` table (the same
    /// pattern Versus/Leagues use for opponent names). Best-effort — missing rows are omitted.
    func authorNames(ids: Set<String>) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        struct ProfileRow: Decodable { let id: String; let username: String? }
        let items = [URLQueryItem(name: "select", value: "id,username"),
                     URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")]
        let rows: [ProfileRow] = (try? await client.select("profiles", query: items,
                                                           decoder: summaryDecoder)) ?? []
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.username.map { (row.id, $0) }
        })
    }

    /// A community puzzle plus the format needed to present it (for share-link / deep-link open).
    /// Carries the author's username so a shared puzzle credits its creator in the explainer.
    enum Loaded { case keep4(Keep4Puzzle, author: String?), whoAmI(WhoAmIPuzzle) }

    func load(id: String) async -> Loaded? {
        struct FormatRow: Decodable {
            let format: String
            let authorId: String
            enum CodingKeys: String, CodingKey { case format; case authorId = "author_id" }
        }
        let items = [URLQueryItem(name: "select", value: "format,author_id"),
                     URLQueryItem(name: "id", value: "eq.\(id)"),
                     URLQueryItem(name: "limit", value: "1")]
        let rows: [FormatRow]? = try? await client.select("community_puzzles", query: items,
                                                          decoder: summaryDecoder)
        switch rows?.first?.format {
        case "keep4":
            guard let row = rows?.first, let puzzle = await keep4(id: id) else { return nil }
            let name = await authorNames(ids: [row.authorId])[row.authorId]
            return .keep4(puzzle, author: name)
        case "whoami": return await whoAmI(id: id).map(Loaded.whoAmI)
        default: return nil
        }
    }

    private func resolve<T: Decodable>(id: String) async -> T? {
        let items = [URLQueryItem(name: "select", value: "content"),
                     URLQueryItem(name: "id", value: "eq.\(id)"),
                     URLQueryItem(name: "limit", value: "1")]
        let rows: [CommunityContentRow<T>]? = try? await client.select(
            "community_puzzles", query: items, decoder: contentDecoder)
        return rows?.first?.content
    }

    // MARK: - Writes (authenticated)

    /// Insert a new community puzzle and return its share id. `content` is encoded with a
    /// plain encoder so its inner keys stay camelCase (the shared encoder would snake-case them).
    @discardableResult
    func create<C: Encodable>(id: String = newID(), authorId: String, sport: Sport, format: String,
                              title: String, content: C, visibility: String = "public") async throws -> String {
        let contentData = try JSONEncoder().encode(content)
        let contentObj = try JSONSerialization.jsonObject(with: contentData)
        let row: [String: Any] = [
            "id": id, "author_id": authorId, "sport": sport.rawValue, "format": format,
            "title": title, "content": contentObj, "visibility": visibility,
        ]
        let body = try JSONSerialization.data(withJSONObject: [row])
        let req = client.restRequest(table: "community_puzzles", method: "POST",
                                     body: body, prefer: "return=minimal")
        try await client.perform(req)
        return id
    }

    /// 7-day play counts (puzzle id → plays) for the This Week sort, via the
    /// `weekly_play_counts` RPC. Throws when the function isn't deployed yet — callers
    /// keep the recent ordering in that case.
    func weeklyPlayCounts() async throws -> [String: Int] {
        struct Row: Decodable {
            let puzzleId: String
            let plays: Int
            enum CodingKeys: String, CodingKey { case puzzleId = "puzzle_id", plays }
        }
        struct NoArgs: Encodable {}
        let data = try await client.rpc("weekly_play_counts", args: NoArgs())
        let rows = try summaryDecoder.decode([Row].self, from: data)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.puzzleId, $0.plays) })
    }

    /// Log a play (drives play_count via the DB trigger). Best-effort; duplicates are ignored.
    func recordPlay(id: String, userID: String) async {
        struct Play: Encodable { let puzzleId: String; let userId: String }
        try? await client.insert("community_plays", values: Play(puzzleId: id, userId: userID))
    }

    func report(id: String, userID: String, reason: String?) async {
        struct Report: Encodable { let puzzleId: String; let reporterId: String; let reason: String? }
        try? await client.insert("community_reports",
                                 values: Report(puzzleId: id, reporterId: userID, reason: reason))
    }

    func delete(id: String) async throws {
        let req = client.restRequest(table: "community_puzzles", method: "DELETE",
                                     query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                                     prefer: "return=minimal")
        try await client.perform(req)
    }

    // MARK: - Moderation (admin review — RLS gates everything below to `profiles.is_admin`)

    /// Whether `userID` holds the operator flag. Best-effort false (also false before the
    /// M12 schema section is applied and the `is_admin` column exists).
    func isAdmin(userID: String) async -> Bool {
        struct Row: Decodable {
            let isAdmin: Bool
            enum CodingKeys: String, CodingKey { case isAdmin = "is_admin" }
        }
        let items = [URLQueryItem(name: "select", value: "is_admin"),
                     URLQueryItem(name: "id", value: "eq.\(userID)"),
                     URLQueryItem(name: "limit", value: "1")]
        let rows: [Row]? = try? await client.select("profiles", query: items, decoder: summaryDecoder)
        return rows?.first?.isAdmin ?? false
    }

    /// Raw report rows, newest first — grouped into per-puzzle cases by
    /// `ModerationPolicy.reviewCases`. Admins see all rows; others only their own.
    func reports(limit: Int = 200) async throws -> [CommunityReport] {
        let items = [URLQueryItem(name: "select", value: "puzzle_id,reporter_id,reason,created_at"),
                     URLQueryItem(name: "order", value: "created_at.desc"),
                     URLQueryItem(name: "limit", value: "\(limit)")]
        return try await client.select("community_reports", query: items, decoder: summaryDecoder)
    }

    /// Feed-shaped summaries for specific ids, `visibility` included and hidden rows visible
    /// (the admin select policy allows them). Missing/deleted ids are simply absent.
    func summaries(ids: [String]) async throws -> [CommunitySummary] {
        guard !ids.isEmpty else { return [] }
        let items = [
            URLQueryItem(name: "select",
                         value: "id,author_id,sport,format,title,play_count,created_at,visibility,description:content->>description,scoring:content->>scoring"),
            URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"),
        ]
        return try await client.select("community_puzzles", query: items, decoder: summaryDecoder)
    }

    /// Admin: flip a puzzle's visibility ("public" to restore, "hidden" to take down).
    func setVisibility(id: String, visibility: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["visibility": visibility])
        let req = client.restRequest(table: "community_puzzles", method: "PATCH",
                                     query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                                     body: body, prefer: "return=minimal")
        try await client.perform(req)
    }

    /// Admin: clear a puzzle's reports — done on restore so the very next report doesn't
    /// immediately re-trip the auto-hide threshold.
    func clearReports(puzzleID: String) async throws {
        let req = client.restRequest(table: "community_reports", method: "DELETE",
                                     query: [URLQueryItem(name: "puzzle_id", value: "eq.\(puzzleID)")],
                                     prefer: "return=minimal")
        try await client.perform(req)
    }

    /// 8-char Crockford-ish base32 share code (no vowels/ambiguous chars).
    static func newID() -> String {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}
