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
final class PlayerSeasonCatalog {
    private let client: SupabaseClient?
    /// `stats` jsonb keys must stay snake_case for GradeFormula — plain decoder, no key strategy.
    private let decoder: JSONDecoder = JSONDecoder()
    private lazy var bundled: [CatalogSeason] = Self.loadBundle()

    init(client: SupabaseClient?) { self.client = client }

    /// Real seasons matching the discovery facets. `rank` (optional) orders results so strong
    /// candidates surface first — purely a display convenience, never a filter. Returns up to `limit`.
    func search(_ q: CatalogQuery, rank: ((CatalogSeason) -> Double)? = nil,
                limit: Int = 80) async -> [CatalogSeason] {
        let remote = await fetchRemote(q, limit: limit)
        let pool = remote ?? filterBundled(q)
        let ordered: [CatalogSeason]
        if let rank {
            ordered = pool.sorted { rank($0) > rank($1) }
        } else {
            ordered = pool.sorted { ($0.seasonYear, $0.name) > ($1.seasonYear, $1.name) }
        }
        return Array(ordered.prefix(limit))
    }

    // MARK: - Remote

    private func fetchRemote(_ q: CatalogQuery, limit: Int) async -> [CatalogSeason]? {
        guard let client else { return nil }
        var items = [
            URLQueryItem(name: "select", value: "id,sport,name,team_abbr,season_year,position,stats,"
                         + "headshot,career,first_year,last_year"),
            URLQueryItem(name: "limit", value: "\(limit * 3)"),   // over-fetch; we re-rank client-side
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
        if let team = q.team, !team.isEmpty {
            items.append(URLQueryItem(name: "team_abbr", value: "ilike.*\(team)*"))
        }
        let name = q.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            items.append(URLQueryItem(name: "name", value: "ilike.*\(name)*"))
        }
        guard let rows: [CatalogSeason] = try? await client.select(
            "player_seasons", query: items, decoder: decoder), !rows.isEmpty else { return nil }
        return rows
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
                && (team == nil || team!.isEmpty || s.teamAbbr.lowercased().contains(team!))
                && (name.isEmpty || s.name.lowercased().contains(name))
                && s.isCareer == q.career
        }
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
