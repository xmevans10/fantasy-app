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

    func keep4Puzzle(for filter: SportFilter, date: Date) async -> DailyPick<Keep4Puzzle>? {
        if let rows = await fetch(format: "keep4", filter: filter, as: Keep4Puzzle.self), !rows.isEmpty {
            return pick(rows, date: date)
        }
        return await fallback.keep4Puzzle(for: filter, date: date)
    }

    func whoAmIPuzzle(for filter: SportFilter, date: Date) async -> DailyPick<WhoAmIPuzzle>? {
        if let rows = await fetch(format: "whoami", filter: filter, as: WhoAmIPuzzle.self), !rows.isEmpty {
            return pick(rows, date: date)
        }
        return await fallback.whoAmIPuzzle(for: filter, date: date)
    }

    func allKeep4(for filter: SportFilter) async -> [Keep4Puzzle] {
        if let rows = await fetch(format: "keep4", filter: filter, as: Keep4Puzzle.self), !rows.isEmpty {
            let released = Self.released(rows)
            if !released.isEmpty { return released.map(\.content) }
        }
        return await fallback.allKeep4(for: filter)
    }

    func allWhoAmI(for filter: SportFilter) async -> [WhoAmIPuzzle] {
        if let rows = await fetch(format: "whoami", filter: filter, as: WhoAmIPuzzle.self), !rows.isEmpty {
            let released = Self.released(rows)
            if !released.isEmpty { return released.map(\.content) }
        }
        return await fallback.allWhoAmI(for: filter)
    }

    /// Drops rows dated later than today — the archive is "everything up to and including
    /// today", never a preview of content that hasn't dropped.
    ///
    /// This became load-bearing when the mint moved to a 2-day lookahead (2026-07-28): the
    /// pool now *always* contains unreleased rows, and Browse would otherwise list tomorrow's
    /// daily as a replayable archive entry — letting a Pro subscriber play tomorrow's puzzle
    /// today and spoiling the daily it's about to be served as. Undated rows (the older
    /// non-canonical pool) are always released; only a date strictly in the future is held back.
    private static func released<T>(_ rows: [PuzzleContentRow<T>]) -> [PuzzleContentRow<T>] {
        let today = PuzzleStore.localDayString()
        return rows.filter { row in
            guard let date = row.activeDate else { return true }
            return date <= today
        }
    }

    /// Grid has no bundled offline fallback (see protocol doc comment) — nil when the table
    /// has nothing for `filter`'s sport today, rather than falling through to anything local.
    func gridPuzzle(for filter: SportFilter, date: Date) async -> DailyPick<GridPuzzle>? {
        guard let rows = await fetch(format: "grid", filter: filter, as: GridPuzzle.self), !rows.isEmpty else {
            return nil
        }
        return pick(rows, date: date)
    }

    /// Deliberately the `random_grid_puzzle` RPC rather than reusing `fetch` + `randomElement()`.
    /// `fetch` pulls the sport's *entire* grid pool, and NFL board content averages 64 KB (cells
    /// carry 149-425 answer names), so a client-side pick would grow the payload linearly with
    /// the pool — the exact thing that blocks deepening the pool enough for "random" to feel
    /// random. The RPC returns one board whatever the pool size.
    private struct RandomGridArgs: Encodable {
        let p_sport: String
        let p_exclude_date: String?
    }
    func randomGridPuzzle(for filter: SportFilter, excludingDate: String?) async -> GridPuzzle? {
        guard let sport = filter.sport else { return nil }
        let args = RandomGridArgs(p_sport: sport.rawValue, p_exclude_date: excludingDate)
        guard let data = try? await client.rpc("random_grid_puzzle", args: args) else { return nil }
        // The RPC returns SQL NULL (encoded as `null`) once the pool is exhausted — a real state
        // today, not an error: baseball has exactly one board ever minted, so excluding today's
        // leaves nothing. Decode failure and "no board" are the same outcome for the caller.
        // `contentDecoder` (plain), not `JSONDecoder.supabase` — board content is camelCase,
        // mirroring grid.to_content's JSON exactly, and the shared Supabase decoder's
        // snake_case key strategy would silently fail to decode it.
        return try? contentDecoder.decode(GridPuzzle.self, from: data)
    }

    /// Sport-wide player-name index for the Grid typeahead, via the `grid_player_names` RPC
    /// (one array — bypasses PostgREST's 1000-row table cap). Names change rarely, so a cached
    /// copy is honored for a week before refetching; a failed fetch falls back to any stale
    /// copy, then to `[]` (the Grid simply offers no suggestions, still fully playable).
    ///
    /// The `-v2-` in the cache key is a manual invalidation lever, not decoration. `DiskCache` has
    /// no version field, so the 7-day TTL below is the ONLY expiry — which means a catalog change
    /// that adds players is invisible to every existing install for up to a week, and cannot be
    /// pushed from the server. That shipped as a real bug: the 2026-07-31 defensive-player ingest
    /// added 5,547 players (Khalil Mack among them), the RPC returned them immediately, and the
    /// Grid typeahead still couldn't suggest a single one. **Bump this suffix whenever the catalog
    /// gains players you expect users to be able to type.**
    private struct NameIndexArgs: Encodable { let p_sport: String }
    func playerNameIndex(for sport: Sport) async -> [String] {
        let key = "grid-names-v2-\(sport.rawValue)"
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

    /// The sport's membership relation, powering client-side board generation. Same shape as
    /// `playerNameIndex` above — one sport-wide RPC, one array, a week of disk cache — because it
    /// is the same kind of payload: rarely-changing reference data whose whole value is not
    /// having to ask the server per board. Measured on the wire (gzipped), v1 → v2 after the axis
    /// arrays landed: nfl 69→93 KB, nba 61→85, baseball 118→165, soccer 270→406, tennis 15→17.
    /// Worth it against 64 KB for a *single* NFL board: even soccer, the worst case, costs about
    /// what six boards do — once a week — and then generates an unbounded number of them offline.
    ///
    /// `contentDecoder`, not `JSONDecoder.supabase`: the payload is camelCase (`minYear`), and
    /// the shared decoder's snake_case key strategy would fail to decode it silently — the exact
    /// trap that made Grid content look like an empty pool once already.
    /// `p_version` is NOT optional here even though the RPC defaults it. The default is 1, and a
    /// v1 payload carries no `axes` — which silently costs three of the five archetypes, because
    /// `GridLocalGenerator.feasibleArchetypes` bails at `guard index.hasAxes` and is left with
    /// teams-x-decades and teams-x-teams only. Symptom on device: every practice board comes back
    /// teams-on-both-axes, i.e. exactly the sameness the v2 axis work existed to remove. Omitting
    /// this argument is not a smaller request, it is a different and much worse one.
    private struct MembershipArgs: Encodable {
        let p_sport: String
        let p_version = GridMembershipIndex.currentVersion
    }
    func gridMembershipIndex(for sport: Sport) async -> GridMembershipIndex? {
        // `-v2-` for the same reason as `playerNameIndex`'s key, and it must be bumped in step with
        // it: this payload decides which players on-device generation can put ON a board, so a
        // stale copy means locally-generated practice boards keep drawing from the old catalog even
        // once the typeahead has refreshed. See that method's note for the full history.
        let key = "grid-memberships-v2-\(sport.rawValue)"
        // The version check is load-bearing, not belt-and-braces. `isUsable` deliberately accepts
        // v1 so a payload cached by an older build still plays — but honouring a *fresh-enough*
        // v1 here would pin an upgraded install to the axis-less shape for the rest of the
        // week-long TTL, which is the same teams-only board the p_version fix exists to end.
        // An out-of-date version falls through to the fetch; the stale branch below still takes
        // v1 if that fetch fails, so nothing regresses offline.
        if let entry = await DiskCache.read(GridMembershipIndex.self, key: key),
           Date().timeIntervalSince(entry.writtenAt) < 7 * 24 * 3600, entry.value.isUsable,
           entry.value.version >= GridMembershipIndex.currentVersion {
            return entry.value
        }
        if let data = try? await client.rpc("grid_membership_index",
                                            args: MembershipArgs(p_sport: sport.rawValue)),
           let index = try? contentDecoder.decode(GridMembershipIndex.self, from: data),
           index.isUsable {
            await DiskCache.write(index, key: key)
            return index
        }
        // A stale index is still a complete, playable one — memberships are historical facts, so
        // the only thing a week-old copy misses is the current season's new signings.
        if let stale = await DiskCache.read(GridMembershipIndex.self, key: key), stale.value.isUsable {
            return stale.value
        }
        return nil
    }

    /// Prefer the row minted for the device's *local* calendar day (`active_date`, written by
    /// tools/ingest/daily_puzzle.py) — a fresh puzzle appears at the user's own midnight, and
    /// the pipeline mints days ahead so that row already exists whatever the timezone. Falls
    /// back to the old modulo pick over the full ordered pool when no row matches today (a day
    /// before this shipped, a missed Action run, or a format/sport with no dated rows). The
    /// `isCanonicalToday` flag on the result IS that match/fallback distinction — callers
    /// (the "TODAY" badge) must not claim freshness on the fallback branch.
    private func pick<T>(_ rows: [PuzzleContentRow<T>], date: Date) -> DailyPick<T> {
        let today = PuzzleStore.localDayString(date)
        if let match = rows.first(where: { $0.activeDate == today }) {
            return DailyPick(content: match.content, isCanonicalToday: true)
        }
        return DailyPick(content: rows[PuzzleStore.dailyIndex(count: rows.count, date: date)].content,
                          isCanonicalToday: false)
    }

    /// Same shape as `PlayerSeasonCatalog`'s arcade-pool disk cache: a fresh copy skips the
    /// network on every cold launch after the first. Freshness is "holds today's dated row"
    /// rather than a write-time TTL — the one thing a daily cache must guarantee is that
    /// `pick()` above can find the row for the user's current local day.
    private func fetch<T: Codable>(format: String, filter: SportFilter, as type: T.Type) async -> [PuzzleContentRow<T>]? {
        let key = "puzzles-\(format)-\(filter.rawValue)"
        let today = PuzzleStore.localDayString()
        // A cache counts only while it actually holds today's dated row. Age alone proves
        // nothing either way: a same-day cache written BEFORE the day's row existed would pin
        // the day to the modulo fallback (hit live 2026-07-17 — a morning launch pinned the
        // Grid to July 8's board all day), while a cache written *yesterday* legitimately
        // holds today's row, because the ingest pipeline mints days ahead — that's what makes
        // the local-midnight rollover instant (and offline-tolerant) instead of a fetch race.
        // Formats/sports with no dated row for today refetch per call instead — small pools,
        // and the stale-cache path below still covers offline.
        if let entry = await DiskCache.read([PuzzleContentRow<T>].self, key: key),
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
