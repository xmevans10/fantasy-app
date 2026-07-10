import Foundation

/// Independent discovery facets for finding catalog candidates. None of these constrain the
/// final puzzle — they're scratch tools to locate seasons in a 6,800-row catalog. A creator
/// can run several different queries and accumulate a mixed-position, mixed-era pool that fits
/// their theme. Empty/nil fields mean "any".
struct CatalogQuery: Equatable {
    var sport: Sport?
    var positions: [String] = []
    var minYear: Int?
    var maxYear: Int?
    var team: String?
    /// An exact team abbreviation for game surfaces that already know the franchise (for
    /// example Draft & Spin after its reel lands). Creation search keeps using `team`'s
    /// forgiving substring match; game queries should not download every team in a season
    /// only to discard them on-device.
    var exactTeam: String?
    var name: String = ""
    /// true → only career-aggregate rows; false (default) → only season rows. Always
    /// applied (never "any") so a season template's pool never accidentally mixes in a
    /// career aggregate's wildly different stat magnitudes, and vice versa (M17).
    var career: Bool = false

    static let empty = CatalogQuery()
}

/// Searchable catalog of real player-seasons (the `player_seasons` table, populated by
/// `tools/ingest --catalog`). Backs the Keep4 creation picker. Falls back to the bundled
/// `player_seasons.json` when the table is empty or the device is offline, so creation
/// works before the catalog is populated.
@MainActor
final class PlayerSeasonCatalog {
    private let client: SupabaseClient?
    /// `stats` jsonb keys must stay snake_case for GradeFormula — plain decoder, no key strategy.
    private let decoder: JSONDecoder = JSONDecoder()
    private lazy var bundled: [CatalogSeason] = Self.loadBundle()
    /// Draft & Spin has a very different access pattern from creation: it needs a broad
    /// discovery pool once, then exact team-year rosters many times in one session. Retain
    /// both in memory so every new round is one narrow request at most (and a reroll often
    /// costs no network at all), without changing the randomness of the actual spin.
    private var draftSpinSamples: [Sport: [CatalogSeason]] = [:]
    private var draftSpinRosters: [String: [CatalogSeason]] = [:]
    private var draftSpinSampleTasks: [Sport: Task<[CatalogSeason], Never>] = [:]
    private var draftSpinRosterTasks: [String: Task<[CatalogSeason], Never>] = [:]

    init(client: SupabaseClient?) { self.client = client }

    /// Real seasons matching the discovery facets. `rank` (optional) orders results so strong
    /// candidates surface first — purely a display convenience, never a filter. Returns up to `limit`.
    func search(_ q: CatalogQuery, rank: ((CatalogSeason) -> Double)? = nil,
                limit: Int = 80) async -> [CatalogSeason] {
        // Ranking needs a wider candidate set to remain meaningful. Plain discovery/search
        // callers already receive the requested number of rows, so multiplying their request
        // by three only adds serial PostgREST pages and launch latency.
        let remote = await fetchRemote(q, limit: limit, overfetchForRanking: rank != nil)
        let pool = remote ?? filterBundled(q)
        let ordered: [CatalogSeason]
        if let rank {
            ordered = pool.sorted { rank($0) > rank($1) }
        } else {
            ordered = pool.sorted { ($0.seasonYear, $0.name) > ($1.seasonYear, $1.name) }
        }
        return Array(ordered.prefix(limit))
    }

    /// Broad, one-time pool used only to choose a viable team/year. This is deliberately
    /// cached data, not a cached spin: `DraftSpinConstraint.spinRound` still draws from it
    /// with a fresh system RNG for every user action.
    func draftSpinSample(for sport: Sport) async -> [CatalogSeason] {
        if let cached = draftSpinSamples[sport] { return cached }
        if let task = draftSpinSampleTasks[sport] { return await task.value }
        let task = Task<[CatalogSeason], Never> { [weak self] in
            guard let self else { return [] }
            return await self.search(CatalogQuery(sport: sport), limit: 2_000)
        }
        draftSpinSampleTasks[sport] = task
        let seasons = await task.value
        draftSpinSampleTasks[sport] = nil
        draftSpinSamples[sport] = seasons
        return seasons
    }

    /// Safe to call when a setup screen first appears or its sport changes. In-flight requests
    /// are coalesced above, so pressing Start while this is still loading never doubles traffic.
    func prefetchDraftSpinSample(for sport: Sport) {
        Task { _ = await draftSpinSample(for: sport) }
    }

    /// Complete roster for the team/year that the reel actually landed on. The exact server
    /// predicate is important: the previous sport+year fetch could return every franchise in
    /// that season and then filter locally.
    func draftSpinRoster(sport: Sport, team: String, year: Int) async -> [CatalogSeason] {
        let key = "\(sport.rawValue)|\(team)|\(year)"
        if let cached = draftSpinRosters[key] { return cached }
        if let task = draftSpinRosterTasks[key] { return await task.value }
        let task = Task<[CatalogSeason], Never> { [weak self] in
            guard let self else { return [] }
            return await self.search(CatalogQuery(sport: sport, minYear: year, maxYear: year,
                                                  exactTeam: team), limit: 1_000)
        }
        draftSpinRosterTasks[key] = task
        let roster = await task.value
        draftSpinRosterTasks[key] = nil
        draftSpinRosters[key] = roster
        return roster
    }

    // MARK: - Remote

    /// PostgREST's own server-configured response cap (this project: 1000 rows) applies
    /// regardless of any `limit=` query param — the same limit the Python Grid pipeline's
    /// `fetch_player_seasons` had to page around. A query with a narrow filter (position/team/
    /// name) never approaches this, but an unfiltered sport-wide fetch (Draft & Spin, Over/Under)
    /// easily does for a big sport, so `fetchRemote` pages in chunks of this size instead of
    /// trusting a single request to return everything asked for.
    private static let pageSize = 1000

    private func fetchRemote(_ q: CatalogQuery, limit: Int,
                             overfetchForRanking: Bool) async -> [CatalogSeason]? {
        guard let client else { return nil }
        var items = [
            URLQueryItem(name: "select", value: "id,sport,name,team_abbr,season_year,position,stats,"
                         + "headshot,career,first_year,last_year"),
            // Stable order is required, not cosmetic: without it, *which* rows a capped response
            // contains isn't even guaranteed consistent across calls (verified in the Grid
            // pipeline bug) — a paginated fetch built on an unordered result could silently drop
            // or duplicate rows between pages.
            URLQueryItem(name: "order", value: "id"),
            URLQueryItem(name: "career", value: "eq.\(q.career)"),
        ]
        if let sport = q.sport {
            items.append(URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)"))
        }
        if !q.positions.isEmpty {
            items.append(URLQueryItem(name: "position", value: "in.(\(q.positions.joined(separator: ",")))"))
        }
        if let minYear = q.minYear {
            items.append(URLQueryItem(name: "season_year", value: "gte.\(minYear)"))
        }
        if let maxYear = q.maxYear {
            items.append(URLQueryItem(name: "season_year", value: "lte.\(maxYear)"))
        }
        if let team = q.exactTeam, !team.isEmpty {
            items.append(URLQueryItem(name: "team_abbr", value: "eq.\(team)"))
        } else if let team = q.team, !team.isEmpty {
            items.append(URLQueryItem(name: "team_abbr", value: "ilike.*\(team)*"))
        }
        let name = q.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            items.append(URLQueryItem(name: "name", value: "ilike.*\(name)*"))
        }

        let target = limit * (overfetchForRanking ? 3 : 1)
        var rows: [CatalogSeason] = []
        var offset = 0
        while rows.count < target {
            let want = min(Self.pageSize, target - rows.count)
            guard let page: [CatalogSeason] = try? await client.select(
                "player_seasons", query: items, range: (offset, offset + want - 1), decoder: decoder),
                !page.isEmpty else { break }
            rows += page
            if page.count < want { break }   // fewer than requested — reached the end of the table
            offset += page.count
        }
        return rows.isEmpty ? nil : rows
    }

    // MARK: - Bundled fallback

    private func filterBundled(_ q: CatalogQuery) -> [CatalogSeason] {
        let name = q.name.trimmingCharacters(in: .whitespaces).lowercased()
        let team = q.team?.lowercased()
        return bundled.filter { s in
            (q.sport == nil || s.sport == q.sport)
                && (q.positions.isEmpty || q.positions.contains(s.position))
                && (q.minYear == nil || s.seasonYear >= q.minYear!)
                && (q.maxYear == nil || s.seasonYear <= q.maxYear!)
                && (q.exactTeam == nil || q.exactTeam!.isEmpty || s.teamAbbr == q.exactTeam!)
                && (q.exactTeam != nil || team == nil || team!.isEmpty || s.teamAbbr.lowercased().contains(team!))
                && (name.isEmpty || s.name.lowercased().contains(name))
                && s.isCareer == q.career
        }
    }

    /// Distinct team abbreviations for `sport`, sorted alphabetically — powers the favorite-team
    /// picker. Bundled-derived (same offline-first rationale as `yearBounds`): no network call,
    /// no separate teams catalog to maintain. Empty for teamless sports (tennis).
    func teams(for sport: Sport) -> [String] {
        guard sport.hasTeams else { return [] }
        let abbrs = bundled.filter { $0.sport == sport }.map(\.teamAbbr)
        return Array(Set(abbrs)).sorted()
    }

    /// The catalog's overall season-year span, for sizing era controls. Bundled-derived
    /// (good enough; the remote span is a superset and the UI clamps either way).
    var yearBounds: ClosedRange<Int> {
        let years = bundled.map(\.seasonYear)
        guard let lo = years.min(), let hi = years.max(), lo <= hi else { return 1987...2024 }
        return lo...hi
    }

    private static func loadBundle() -> [CatalogSeason] {
        guard let url = Bundle.main.url(forResource: "player_seasons", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CatalogSeason].self, from: data)) ?? []
    }
}
