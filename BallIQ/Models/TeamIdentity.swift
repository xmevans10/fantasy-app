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
struct LeagueIdentity: Equatable {
    let sport: Sport
    let league: String
    let displayName: String?
    let logoURL: URL?

    struct Row: Codable {
        let sport: Sport
        let league: String
        let displayName: String?
        let logoUrl: String?
    }

    init(sport: Sport, league: String, displayName: String?, logoURL: URL?) {
        self.sport = sport
        self.league = league
        self.displayName = displayName
        self.logoURL = logoURL
    }

    init(row: Row) {
        sport = row.sport
        league = row.league
        displayName = row.displayName
        logoURL = row.logoUrl.flatMap(URL.init(string:))
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
        for item in items { leagues[Self.leagueKey(item.sport, item.league)] = item }
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

    func leagueIdentity(sport: Sport, league: String) -> LeagueIdentity? {
        lock.lock(); defer { lock.unlock() }
        return leagues[Self.leagueKey(sport, league)]
    }

    private static func teamKey(_ sport: Sport, _ abbr: String, _ league: String) -> String {
        "\(sport.rawValue)|\(abbr.uppercased())|\(league)"
    }
    private static func leagueKey(_ sport: Sport, _ league: String) -> String {
        "\(sport.rawValue)|\(league)"
    }
}
