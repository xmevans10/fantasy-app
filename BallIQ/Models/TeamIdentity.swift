import SwiftUI

/// One row of the `teams` table — a franchise's real colors/logo/full name, independent of any
/// particular season (unlike `CatalogSeason`, which is season-scoped and only carries a team
/// abbreviation). Feeds the design system so team identity comes from live data instead of the
/// hardcoded tables in `TeamColors`/`Sport` — those stay in place as the offline/cold-launch
/// fallback. PK (sport, team_abbr, league); `league` is '' for NFL/NBA/MLB and a country label
/// for soccer, the same collision rationale `CatalogSeason.league` documents (team codes collide
/// across countries — e.g. "BRO" is both Blackburn Rovers, England and Brisbane Roar, Australia).
struct TeamIdentity: Equatable {
    let sport: Sport
    let abbr: String
    let league: String
    let fullName: String?
    let logoURL: URL?
    let primary: Color?
    let secondary: Color?

    /// Wire row from the `teams` fetch, decoded with the default `.supabase` decoder
    /// (`convertFromSnakeCase`) — plain camelCase properties, no explicit `CodingKeys`, same
    /// pattern `RepositoryContainer`'s other straight-column tables use. `Color` itself isn't
    /// `Decodable`, so the hex columns land here as plain strings and get parsed in
    /// `init(row:)` below; `logoUrl`/colors are optional since the table tolerates unknown
    /// crests/colors rather than blocking a team's row.
    struct Row: Codable {
        let sport: Sport
        let teamAbbr: String
        let league: String
        let fullName: String?
        let logoUrl: String?
        let primaryColor: String?
        let secondaryColor: String?
    }

    init(sport: Sport, abbr: String, league: String, fullName: String?,
        logoURL: URL?, primary: Color?, secondary: Color?) {
        self.sport = sport
        self.abbr = abbr
        self.league = league
        self.fullName = fullName
        self.logoURL = logoURL
        self.primary = primary
        self.secondary = secondary
    }

    init(row: Row) {
        sport = row.sport
        abbr = row.teamAbbr
        league = row.league
        fullName = row.fullName
        logoURL = row.logoUrl.flatMap(URL.init(string:))
        primary = row.primaryColor.flatMap { Color(hexString: $0) }
        secondary = row.secondaryColor.flatMap { Color(hexString: $0) }
    }
}

/// One row of the `leagues` table — a (sport, league) pair's display name + crest (e.g.
/// nfl/'' -> "NFL"; soccer/'England' -> the FA/Premier League badge). Same fallback posture as
/// `TeamIdentity`: nil fields degrade to text, never a broken image.
struct LeagueIdentity: Equatable, Identifiable {
    let sport: Sport
    let league: String
    let displayName: String?
    let logoURL: URL?
    /// The nation this competition belongs to — the grouping level of the FIFA-style
    /// Nation → League → Club hierarchy. Nil for the single-competition US sports.
    let country: String?
    /// Division within `country`: 1 = top flight, 2 = second tier, … Lets one nation carry its
    /// whole ladder (Bundesliga + 2. Bundesliga), which the old country-keyed model could not.
    let tier: Int

    /// `league` is the country label and no longer unique on its own — tier disambiguates.
    var id: String { "\(sport.rawValue)|\(league)|\(tier)" }

    struct Row: Codable {
        let sport: Sport
        let league: String
        let displayName: String?
        let logoUrl: String?
        let country: String?
        let tier: Int?
    }

    init(sport: Sport, league: String, displayName: String?, logoURL: URL?,
         country: String? = nil, tier: Int = 1) {
        self.sport = sport
        self.league = league
        self.displayName = displayName
        self.logoURL = logoURL
        self.country = country
        self.tier = tier
    }

    init(row: Row) {
        sport = row.sport
        league = row.league
        displayName = row.displayName
        logoURL = row.logoUrl.flatMap(URL.init(string:))
        country = row.country
        tier = row.tier ?? 1
    }
}

extension Color {
    /// Parses '#RRGGBB' (leading '#' optional) into the existing UInt32-hex initializer
    /// (`DesignSystem/Theme.swift`) — the `teams` table stores hex as a plain string column,
    /// not the numeric literal that init expects. `fileprivate` would be tidier but this is
    /// also the only sane place a hex-string parser belongs; kept internal in case another
    /// data-driven color column shows up later.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self = Color(hex: value)
    }
}

/// Thread-safe in-memory index of fetched team/league identities, populated by
/// `PlayerSeasonCatalog.warmIdentities(for:)` and consulted synchronously by the design system
/// (`TeamColors`, `TeamLogoBadge`, `LeagueLogoBadge`). A plain class rather than routing every
/// lookup through the (`@MainActor`) catalog itself — `TeamColors` is a non-isolated enum, so
/// this lets it read fetched identity without `await` from any call site, exactly like the
/// hardcoded dictionaries it falls back to. `.shared` is the production instance; call sites
/// that need one also take an injectable instance (default `.shared`) so tests can exercise the
/// data-driven path without mutating global state other tests depend on staying empty.
final class TeamIdentityIndex {
    static let shared = TeamIdentityIndex()

    private let lock = NSLock()
    private var teams: [String: TeamIdentity] = [:]
    private var leagues: [String: LeagueIdentity] = [:]

    init() {}

    func store(teams items: [TeamIdentity]) {
        lock.lock(); defer { lock.unlock() }
        for item in items { teams[Self.teamKey(item.sport, item.abbr, item.league)] = item }
    }

    func store(leagues items: [LeagueIdentity]) {
        lock.lock(); defer { lock.unlock() }
        // Keyed by tier as well as league: `league` is a country label, so a nation with a
        // division ladder (Germany → Bundesliga + 2. Bundesliga) would otherwise overwrite
        // itself and only the last-fetched tier would survive.
        for item in items { leagues[item.id] = item }
    }

    /// League-tolerant lookup: exact (abbr, league) first, then (abbr, '') — most US-sport rows
    /// carry league '' — then any-league match by abbr alone as a last resort. That last step is
    /// only correct when the abbr happens to be unambiguous across leagues; soccer callers
    /// should always pass a real league to avoid the exact cross-country collisions
    /// `CatalogSeason.league` exists to prevent (e.g. "BRO").
    func identity(sport: Sport, abbr: String, league: String?) -> TeamIdentity? {
        lock.lock(); defer { lock.unlock() }
        let key = abbr.uppercased()
        if let league, let exact = teams[Self.teamKey(sport, key, league)] { return exact }
        if let blank = teams[Self.teamKey(sport, key, "")] { return blank }
        return teams.values.first { $0.sport == sport && $0.abbr.uppercased() == key }
    }

    /// A nation's headline competition — the top flight (lowest `tier`) stored for that league
    /// label. Callers that badge a club (which only knows its country label, not its division)
    /// want exactly this; a picker wanting the full ladder uses `allLeagues`.
    func leagueIdentity(sport: Sport, league: String) -> LeagueIdentity? {
        lock.lock(); defer { lock.unlock() }
        return leagues.values
            .filter { $0.sport == sport && $0.league == league }
            .min { $0.tier < $1.tier }
    }

    /// League labels we actually hold clubs for. A competition can exist in the `leagues` catalog
    /// long before any club/player sweep lands for it (every lower division does today), and
    /// filtering the arcade to one of those would search an empty pool — so a picker uses this to
    /// decide what is genuinely selectable. Derived from the fetched clubs rather than a curated
    /// list, so a competition becomes selectable the moment its first sweep lands.
    func leaguesWithTeams(sport: Sport) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(teams.values.filter { $0.sport == sport && !$0.league.isEmpty }.map(\.league))
    }

    /// Every competition stored for `sport`, top flights first then deeper tiers, alphabetical by
    /// nation — the order a nation-grouped picker renders in. Empty until `warmIdentities` lands.
    func allLeagues(sport: Sport) -> [LeagueIdentity] {
        lock.lock(); defer { lock.unlock() }
        return leagues.values
            .filter { $0.sport == sport }
            .sorted {
                let a = ($0.country ?? $0.league), b = ($1.country ?? $1.league)
                if a != b { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
                return $0.tier < $1.tier
            }
    }

    /// The competition a club plays in, for callers that only have an abbreviation. Needed
    /// because `player_seasons.league` is only populated on the ESPN-sourced soccer rows —
    /// live, 87,644 of 93,098 soccer rows (94%) carry a NULL league, since the Transfermarkt
    /// bulk never had one. The `teams` catalog *is* league-qualified for every club, so it's
    /// the reliable place to answer "what league is this club in?" — anything keyed off the
    /// player row alone would resolve for only ~6% of soccer spins.
    /// Returns nil for the single-league US sports (their `teams` rows carry league '').
    func league(sport: Sport, abbr: String) -> String? {
        guard let found = identity(sport: sport, abbr: abbr, league: nil) else { return nil }
        return found.league.isEmpty ? nil : found.league
    }

    private static func teamKey(_ sport: Sport, _ abbr: String, _ league: String) -> String {
        "\(sport.rawValue)|\(abbr.uppercased())|\(league)"
    }
    // League rows key off `LeagueIdentity.id` (sport|league|tier) rather than a helper here —
    // see `store(leagues:)` for why tier has to be part of the key.
}
