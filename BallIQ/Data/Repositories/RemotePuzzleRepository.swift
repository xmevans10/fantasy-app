import Foundation

private struct PuzzleContentRow<Content: Codable>: Codable {
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

    /// Grid has no bundled offline fallback (see protocol doc comment) — nil when the table
    /// has nothing for `filter`'s sport today, rather than falling through to anything local.
    func gridPuzzle(for filter: SportFilter, date: Date) async -> GridPuzzle? {
        guard let rows = await fetch(format: "grid", filter: filter, as: GridPuzzle.self), !rows.isEmpty else {
            return nil
        }
        return pick(rows, date: date)
    }

    /// Sport-wide player-name index for the Grid typeahead, via the `grid_player_names` RPC
    /// (one array — bypasses PostgREST's 1000-row table cap). Names change rarely, so a cached
    /// copy is honored for a week before refetching; a failed fetch falls back to any stale
    /// copy, then to `[]` (the Grid simply offers no suggestions, still fully playable).
    private struct NameIndexArgs: Encodable { let p_sport: String }
    func playerNameIndex(for sport: Sport) async -> [String] {
        let key = "grid-names-\(sport.rawValue)"
        if let entry = await DiskCache.read([String].self, key: key),
           Date().timeIntervalSince(entry.writtenAt) < 7 * 24 * 3600 {
            return entry.value
        }
        if let data = try? await client.rpc("grid_player_names", args: NameIndexArgs(p_sport: sport.rawValue)),
           let names = try? JSONDecoder().decode([String].self, from: data), !names.isEmpty {
            await DiskCache.write(names, key: key)
            return names
        }
        if let stale = await DiskCache.read([String].self, key: key) { return stale.value }
        return []
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

    /// Same shape as `PlayerSeasonCatalog`'s arcade-pool disk cache: a fresh copy skips the
    /// network on every cold launch after the first. Freshness is "written today" rather than
    /// a flat TTL — a new UTC day's daily puzzle row (`active_date`) only exists once the
    /// ingest pipeline mints it, so a launch on a new day MUST refetch or `pick()` above would
    /// never see today's row at all.
    private func fetch<T: Codable>(format: String, filter: SportFilter, as type: T.Type) async -> [PuzzleContentRow<T>]? {
        let key = "puzzles-\(format)-\(filter.rawValue)"
        let today = PuzzleStore.todayUTCString()
        // A same-day cache only counts when it actually holds today's dated row. Written-today
        // alone isn't enough: a launch BEFORE the day's ingest mints the row caches a pool
        // without it, and `pick()` would then silently modulo-pick an old puzzle for the rest
        // of the day (hit live 2026-07-17 — a morning launch pinned the Grid to July 8's
        // board all day). Formats with no dated rows at all (WhoAmI today) refetch once per
        // launch instead — small pools, and the stale-cache path still covers offline.
        if let entry = await DiskCache.read([PuzzleContentRow<T>].self, key: key),
           PuzzleStore.todayUTCString(entry.writtenAt) == today,
           entry.value.contains(where: { $0.activeDate == today }) {
            #if DEBUG
            print("[puzzles] \(Date()) \(key): disk hit (today's row present)")
            #endif
            return entry.value
        }
        var query = [URLQueryItem(name: "select", value: "content,active_date"),
                     URLQueryItem(name: "format", value: "eq.\(format)"),
                     // Stable order is essential: the modulo fallback indexes into this pool by
                     // date, so every device must see the same ordering (PostgREST is otherwise
                     // arbitrary).
                     URLQueryItem(name: "order", value: "id")]
        if let sport = filter.sport {
            query.append(URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)"))
        }
        if let remote: [PuzzleContentRow<T>] = try? await client.select("puzzles", query: query, decoder: contentDecoder),
           !remote.isEmpty {
            #if DEBUG
            print("[puzzles] \(Date()) \(key): network fetch (\(remote.count) rows)")
            #endif
            await DiskCache.write(remote, key: key)
            return remote
        }
        // Network failed (or the table was briefly empty) — a stale cached pool is still real
        // data, unlike the bundled fallback callers reach for when `fetch` returns nil.
        if let stale = await DiskCache.read([PuzzleContentRow<T>].self, key: key) {
            #if DEBUG
            print("[puzzles] \(Date()) \(key): disk hit (stale, network failed)")
            #endif
            return stale.value
        }
        return nil
    }
}
