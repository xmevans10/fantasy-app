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
    /// Exact `CatalogSeason.league` match, alongside `exactTeam` — defense in depth against team
    /// codes that collide across countries (e.g. "BRO" is both Blackburn Rovers, England and
    /// Brisbane Roar, Australia; live collision in seasons 2009-2011). nil = no league predicate,
    /// matching every row regardless of league — required for rows that don't populate league yet
    /// (Transfermarkt-sourced soccer rows, `season.league == nil`).
    var league: String?
    var name: String = ""
    /// Which of the three grains to search — season (default), career-aggregate, or
    /// single-game. Always applied (never "any") so one template's pool never accidentally
    /// mixes in another grain's wildly different stat magnitudes (M17, extended to game
    /// grain for single-game creation).
    var grain: PuzzleGrain = .season

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
            return await self.loadDraftSpinSample(for: sport)
        }
        draftSpinSampleTasks[sport] = task
        let seasons = await task.value
        draftSpinSampleTasks[sport] = nil
        draftSpinSamples[sport] = seasons
        return seasons
    }

    /// The ~1MB, 2-request fetch that drives the ~15s Over/Under & Draft & Spin cold-launch
    /// latency (BALLIQ_SPEC §9 backlog #3) — a disk cache sits between the in-memory sample
    /// and the network so only the FIRST app session of the day pays for it. A network
    /// failure still prefers a stale disk copy over the ~500-row bundle: real (if dated)
    /// data beats a trimmed sample.
    private static let diskCacheTTL: TimeInterval = 24 * 60 * 60
    private static func diskCacheKey(for sport: Sport) -> String { "arcade-pool-\(sport.rawValue)" }

    private func loadDraftSpinSample(for sport: Sport) async -> [CatalogSeason] {
        let key = Self.diskCacheKey(for: sport)
        if let entry = await DiskCache.read([CatalogSeason].self, key: key),
           Date().timeIntervalSince(entry.writtenAt) < Self.diskCacheTTL {
            #if DEBUG
            print("[catalog] \(Date()) arcade sample \(sport.rawValue): disk hit (fresh)")
            #endif
            return entry.value
        }
        let q = CatalogQuery(sport: sport)
        if let remote = await fetchRemote(q, limit: 2_000, overfetchForRanking: false) {
            #if DEBUG
            print("[catalog] \(Date()) arcade sample \(sport.rawValue): network fetch (\(remote.count) rows)")
            #endif
            let ordered = Self.ordered(remote)
            await DiskCache.write(ordered, key: key)
            return ordered
        }
        if let stale = await DiskCache.read([CatalogSeason].self, key: key) {
            #if DEBUG
            print("[catalog] \(Date()) arcade sample \(sport.rawValue): disk hit (stale, network failed)")
            #endif
            return stale.value
        }
        #if DEBUG
        print("[catalog] \(Date()) arcade sample \(sport.rawValue): bundled fallback")
        #endif
        return Self.ordered(filterBundled(q))
    }

    private static func ordered(_ seasons: [CatalogSeason]) -> [CatalogSeason] {
        Array(seasons.sorted { ($0.seasonYear, $0.name) > ($1.seasonYear, $1.name) }.prefix(2_000))
    }

    /// Safe to call when a setup screen first appears or its sport changes. In-flight requests
    /// are coalesced above, so pressing Start while this is still loading never doubles traffic.
    /// Also warms the team/league identity index (design-system foundation slice) — every arcade
    /// setup screen that prefetches a pool is exactly the moment a card is about to render team
    /// colors/logos, so this is the one place that reliably fires before that without touching
    /// any feature view directly.
    func prefetchDraftSpinSample(for sport: Sport) {
        Task { _ = await draftSpinSample(for: sport) }
        warmIdentities(for: sport)
    }

    /// Every arcade format's session pool, served from the same cached broad sample Draft &
    /// Spin discovers from — Over/Under's 200-row pool is just its prefix, so one warm fetch
    /// (Home's prefetch, or either format's setup screen) makes BOTH formats open instantly.
    func arcadePool(for sport: Sport, limit: Int) async -> [CatalogSeason] {
        Array(await draftSpinSample(for: sport).prefix(limit))
    }

    /// Complete roster for the team/year that the reel actually landed on. The exact server
    /// predicate is important: the previous sport+year fetch could return every franchise in
    /// that season and then filter locally. `league` (from the spun `TeamYear`, nil for sports/
    /// rows that don't carry one) scopes the predicate further — team codes collide across
    /// countries (e.g. "BRO" is Blackburn Rovers, England AND Brisbane Roar, Australia), so
    /// sport+team+year alone can pull a roster that mixes two different clubs' players.
    func draftSpinRoster(sport: Sport, team: String, year: Int, league: String? = nil) async -> [CatalogSeason] {
        let key = "\(sport.rawValue)|\(team)|\(year)|\(league ?? "")"
        if let cached = draftSpinRosters[key] { return cached }
        if let task = draftSpinRosterTasks[key] { return await task.value }
        let task = Task<[CatalogSeason], Never> { [weak self] in
            guard let self else { return [] }
            let query = CatalogQuery(sport: sport, minYear: year, maxYear: year,
                                     exactTeam: team, league: league)
            let rows = await self.search(query, limit: 1_000)
            // `search` collapses a failed fetch and a genuinely-empty result into the same
            // empty array (the remote call is wrapped in `try?`, then falls through to the
            // small bundled catalog). A real team-season is never actually empty, so treat
            // empty as "we didn't get an answer" and give it one more chance before the board
            // renders "No players match." on a roster that does exist server-side.
            return rows.isEmpty ? await self.search(query, limit: 1_000) : rows
        }
        draftSpinRosterTasks[key] = task
        let roster = await task.value
        draftSpinRosterTasks[key] = nil
        // Never memoize an empty roster: a transient failure would otherwise stay "empty" for
        // the rest of the session, so even rerolling back onto this combo could not recover.
        if !roster.isEmpty { draftSpinRosters[key] = roster }
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
                         + "headshot,career,first_year,last_year,league,week,opponent,game_date"),
            // Stable order is required, not cosmetic: without it, *which* rows a capped response
            // contains isn't even guaranteed consistent across calls (verified in the Grid
            // pipeline bug) — a paginated fetch built on an unordered result could silently drop
            // or duplicate rows between pages.
            URLQueryItem(name: "order", value: "id"),
            URLQueryItem(name: "career", value: "eq.\(q.grain == .career)"),
        ]
        // Season vs single-game are both career=false — distinguish by whether `week` is
        // set. Career rows never have `week` set either way, so this filter is skipped for
        // them (the `career=eq.true` predicate above already scopes the pool correctly).
        switch q.grain {
        case .season:     items.append(URLQueryItem(name: "week", value: "is.null"))
        case .singleGame: items.append(URLQueryItem(name: "week", value: "not.is.null"))
        case .career:     break
        }
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
        if let league = q.league, !league.isEmpty {
            items.append(URLQueryItem(name: "league", value: "eq.\(league)"))
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

    // MARK: - Team/league identities (data-driven colors/logos foundation)

    /// Team/league rows are essentially static week to week (a franchise doesn't change colors
    /// mid-season) — a much longer TTL than the arcade pool's, since there's no freshness
    /// pressure to trade off against, just cold-launch network avoidance.
    private static let identityCacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private var teamIdentityTasks: [Sport: Task<[TeamIdentity], Never>] = [:]
    private var leagueIdentityTasks: [Sport: Task<[LeagueIdentity], Never>] = [:]

    /// Fetches every `teams` row for `sport`, disk-cached for a week. Also stores the result
    /// into `TeamIdentityIndex.shared` so `TeamColors`/`TeamLogoBadge` can resolve colors/logos
    /// synchronously without threading this catalog through every call site — callers that just
    /// want the warm side-effect should use `warmIdentities(for:)` instead of awaiting this.
    func teamIdentities(for sport: Sport) async -> [TeamIdentity] {
        if let task = teamIdentityTasks[sport] { return await task.value }
        let task = Task<[TeamIdentity], Never> { [weak self] in
            guard let self else { return [] }
            return await self.loadTeamIdentities(for: sport)
        }
        teamIdentityTasks[sport] = task
        let items = await task.value
        teamIdentityTasks[sport] = nil
        return items
    }

    private func loadTeamIdentities(for sport: Sport) async -> [TeamIdentity] {
        let key = "teams-\(sport.rawValue)"
        if let entry = await DiskCache.read([TeamIdentity.Row].self, key: key),
           Date().timeIntervalSince(entry.writtenAt) < Self.identityCacheTTL {
            return store(TeamIdentity.init(row:), entry.value)
        }
        let query = [URLQueryItem(name: "select", value: "sport,team_abbr,league,full_name,logo_url,"
                                   + "primary_color,secondary_color,competition"),
                     URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)")]
        if let client, let rows: [TeamIdentity.Row] = try? await client.select("teams", query: query) {
            await DiskCache.write(rows, key: key)
            return store(TeamIdentity.init(row:), rows)
        }
        if let stale = await DiskCache.read([TeamIdentity.Row].self, key: key) {
            return store(TeamIdentity.init(row:), stale.value)
        }
        return []
    }

    /// Same shape as `teamIdentities(for:)`, for the `leagues` table's per-(sport, league)
    /// display name + crest.
    func leagueIdentities(for sport: Sport) async -> [LeagueIdentity] {
        if let task = leagueIdentityTasks[sport] { return await task.value }
        let task = Task<[LeagueIdentity], Never> { [weak self] in
            guard let self else { return [] }
            return await self.loadLeagueIdentities(for: sport)
        }
        leagueIdentityTasks[sport] = task
        let items = await task.value
        leagueIdentityTasks[sport] = nil
        return items
    }

    private func loadLeagueIdentities(for sport: Sport) async -> [LeagueIdentity] {
        let key = "leagues-\(sport.rawValue)"
        if let entry = await DiskCache.read([LeagueIdentity.Row].self, key: key),
           Date().timeIntervalSince(entry.writtenAt) < Self.identityCacheTTL {
            return store(LeagueIdentity.init(row:), entry.value)
        }
        let query = [URLQueryItem(name: "select", value: "sport,league,display_name,logo_url,country,tier,espn_slug"),
                     URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)")]
        if let client, let rows: [LeagueIdentity.Row] = try? await client.select("leagues", query: query) {
            await DiskCache.write(rows, key: key)
            return store(LeagueIdentity.init(row:), rows)
        }
        if let stale = await DiskCache.read([LeagueIdentity.Row].self, key: key) {
            return store(LeagueIdentity.init(row:), stale.value)
        }
        return []
    }

    private func store(_ makeTeam: (TeamIdentity.Row) -> TeamIdentity, _ rows: [TeamIdentity.Row]) -> [TeamIdentity] {
        let items = rows.map(makeTeam)
        TeamIdentityIndex.shared.store(teams: items)
        return items
    }

    private func store(_ makeLeague: (LeagueIdentity.Row) -> LeagueIdentity, _ rows: [LeagueIdentity.Row]) -> [LeagueIdentity] {
        let items = rows.map(makeLeague)
        TeamIdentityIndex.shared.store(leagues: items)
        return items
    }

    /// Synchronous lookups the design system (and, later, feature views) can use once
    /// `warmIdentities(for:)` has populated the shared index — safe to call before that too
    /// (returns nil), since every consumer already has a hardcoded/ESPN-CDN fallback for the
    /// "not loaded yet" case.
    func identity(sport: Sport, abbr: String, league: String? = nil) -> TeamIdentity? {
        TeamIdentityIndex.shared.identity(sport: sport, abbr: abbr, league: league)
    }

    func leagueIdentity(sport: Sport, league: String) -> LeagueIdentity? {
        TeamIdentityIndex.shared.leagueIdentity(sport: sport, league: league)
    }

    /// Fire-and-forget warm of both identity tables for `sport` — pair with any pool prefetch
    /// (setup screens, Home) so synchronous design-system lookups are already populated by the
    /// time a card actually renders.
    func warmIdentities(for sport: Sport) {
        Task { _ = await teamIdentities(for: sport) }
        Task { _ = await leagueIdentities(for: sport) }
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
                && (q.league == nil || s.league == q.league)
                && (name.isEmpty || s.name.lowercased().contains(name))
                && s.isCareer == (q.grain == .career)
                && (q.grain == .career || s.isGame == (q.grain == .singleGame))
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
