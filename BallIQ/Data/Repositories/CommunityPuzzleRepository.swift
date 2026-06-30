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

    enum CodingKeys: String, CodingKey {
        case id, sport, format, title
        case authorId = "author_id"
        case playCount = "play_count"
        case createdAt = "created_at"
    }
}

enum CommunitySort { case recent, popular }

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
                         value: "id,author_id,sport,format,title,play_count,created_at"),
            URLQueryItem(name: "format", value: "eq.\(format)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let authorId {
            items.append(URLQueryItem(name: "author_id", value: "eq.\(authorId)"))
        } else {
            items.append(URLQueryItem(name: "visibility", value: "eq.public"))
        }
        if let sport { items.append(URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)")) }
        let order = sort == .popular ? "play_count.desc" : "created_at.desc"
        items.append(URLQueryItem(name: "order", value: order))

        return try await client.select("community_puzzles", query: items, decoder: summaryDecoder)
    }

    func keep4(id: String) async -> Keep4Puzzle? { await resolve(id: id) }
    func whoAmI(id: String) async -> WhoAmIPuzzle? { await resolve(id: id) }

    /// A community puzzle plus the format needed to present it (for share-link / deep-link open).
    enum Loaded { case keep4(Keep4Puzzle), whoAmI(WhoAmIPuzzle) }

    func load(id: String) async -> Loaded? {
        struct FormatRow: Decodable { let format: String }
        let items = [URLQueryItem(name: "select", value: "format"),
                     URLQueryItem(name: "id", value: "eq.\(id)"),
                     URLQueryItem(name: "limit", value: "1")]
        let rows: [FormatRow]? = try? await client.select("community_puzzles", query: items,
                                                          decoder: summaryDecoder)
        switch rows?.first?.format {
        case "keep4": return await keep4(id: id).map(Loaded.keep4)
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

    /// 8-char Crockford-ish base32 share code (no vowels/ambiguous chars).
    static func newID() -> String {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}
