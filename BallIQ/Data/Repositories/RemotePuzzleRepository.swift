import Foundation

private struct PuzzleContentRow<Content: Decodable>: Decodable { let content: Content }

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
        if let pool = await fetch(format: "keep4", filter: filter, as: Keep4Puzzle.self), !pool.isEmpty {
            return pool[PuzzleStore.dailyIndex(count: pool.count, date: date)]
        }
        return await fallback.keep4Puzzle(for: filter, date: date)
    }

    func whoAmIPuzzle(for filter: SportFilter, date: Date) async -> WhoAmIPuzzle? {
        if let pool = await fetch(format: "whoami", filter: filter, as: WhoAmIPuzzle.self), !pool.isEmpty {
            return pool[PuzzleStore.dailyIndex(count: pool.count, date: date)]
        }
        return await fallback.whoAmIPuzzle(for: filter, date: date)
    }

    func allKeep4(for filter: SportFilter) async -> [Keep4Puzzle] {
        if let pool = await fetch(format: "keep4", filter: filter, as: Keep4Puzzle.self), !pool.isEmpty {
            return pool
        }
        return await fallback.allKeep4(for: filter)
    }

    func allWhoAmI(for filter: SportFilter) async -> [WhoAmIPuzzle] {
        if let pool = await fetch(format: "whoami", filter: filter, as: WhoAmIPuzzle.self), !pool.isEmpty {
            return pool
        }
        return await fallback.allWhoAmI(for: filter)
    }

    private func fetch<T: Decodable>(format: String, filter: SportFilter, as type: T.Type) async -> [T]? {
        var query = [URLQueryItem(name: "select", value: "content"),
                     URLQueryItem(name: "format", value: "eq.\(format)"),
                     // Stable order is essential: the daily pick indexes into this pool by date,
                     // so every device must see the same ordering (PostgREST is otherwise arbitrary).
                     URLQueryItem(name: "order", value: "id")]
        if let sport = filter.sport {
            query.append(URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)"))
        }
        guard let rows: [PuzzleContentRow<T>] = try? await client.select(
            "puzzles", query: query, decoder: contentDecoder) else { return nil }
        return rows.map(\.content)
    }
}
