import Foundation

private struct PuzzleContentRow<Content: Decodable>: Decodable {
    let content: Content
    let activeDate: String?

    private enum CodingKeys: String, CodingKey {
        case content
        case activeDate = "active_date"
    }
}

/// Fetches daily puzzles from Supabase, falling back to the bundled JSON when the table is empty
/// or the device is offline. Implements the same async `PuzzleRepository` protocol.
final class RemotePuzzleRepository: PuzzleRepository {
    private let client: SupabaseClient
    private let fallback = LocalPuzzleRepository()
    /// `content` jsonb stores the puzzle in the same camelCase shape the bundled JSON uses.
    private let contentDecoder = JSONDecoder()

    init(client: SupabaseClient) { self.client = client }

    var availableSports: [Sport] { fallback.availableSports }

    func keep4Puzzle(for filter: SportFilter, date: Date) async -> Keep4Puzzle? {
        if let rows = await fetch(format: "keep4", filter: filter, as: Keep4Puzzle.self), !rows.isEmpty {
            return pick(rows, date: date)
        }
        return await fallback.keep4Puzzle(for: filter, date: date)
    }

    func whoAmIPuzzle(for filter: SportFilter, date: Date) async -> WhoAmIPuzzle? {
        if let rows = await fetch(format: "whoami", filter: filter, as: WhoAmIPuzzle.self), !rows.isEmpty {
            return pick(rows, date: date)
        }
        return await fallback.whoAmIPuzzle(for: filter, date: date)
    }

    func allKeep4(for filter: SportFilter) async -> [Keep4Puzzle] {
        if let rows = await fetch(format: "keep4", filter: filter, as: Keep4Puzzle.self), !rows.isEmpty {
            return rows.map(\.content)
        }
        return await fallback.allKeep4(for: filter)
    }

    func allWhoAmI(for filter: SportFilter) async -> [WhoAmIPuzzle] {
        if let rows = await fetch(format: "whoami", filter: filter, as: WhoAmIPuzzle.self), !rows.isEmpty {
            return rows.map(\.content)
        }
        return await fallback.allWhoAmI(for: filter)
    }

    /// Prefer the row minted for this exact UTC day (`active_date`, written by
    /// tools/ingest/daily_puzzle.py) — every day gets its own genuinely new puzzle. Falls back
    /// to the old modulo pick over the full ordered pool when no row matches today (a day
    /// before this shipped, a missed Action run, or WhoAmI which never gets a dated row yet).
    private func pick<T>(_ rows: [PuzzleContentRow<T>], date: Date) -> T {
        let today = PuzzleStore.todayUTCString(date)
        if let match = rows.first(where: { $0.activeDate == today }) {
            return match.content
        }
        return rows[PuzzleStore.dailyIndex(count: rows.count, date: date)].content
    }

    private func fetch<T: Decodable>(format: String, filter: SportFilter, as type: T.Type) async -> [PuzzleContentRow<T>]? {
        var query = [URLQueryItem(name: "select", value: "content,active_date"),
                     URLQueryItem(name: "format", value: "eq.\(format)"),
                     // Stable order is essential: the modulo fallback indexes into this pool by
                     // date, so every device must see the same ordering (PostgREST is otherwise
                     // arbitrary).
                     URLQueryItem(name: "order", value: "id")]
        if let sport = filter.sport {
            query.append(URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)"))
        }
        return try? await client.select("puzzles", query: query, decoder: contentDecoder)
    }
}
