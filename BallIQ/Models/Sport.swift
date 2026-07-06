import SwiftUI

enum Sport: String, Codable, CaseIterable, Identifiable {
    case nfl
    case nba
    case baseball
    case soccer
    case tennis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nfl: return "NFL"
        case .nba: return "NBA"
        case .baseball: return "MLB"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        }
    }

    var abbreviation: String { displayName }

    /// SF Symbol used in filter pills / format icons.
    var symbol: String {
        switch self {
        case .nfl: return "football.fill"
        case .nba: return "basketball.fill"
        case .baseball: return "baseball.fill"
        case .soccer: return "soccerball"
        case .tennis: return "tennisball.fill"
        }
    }

    /// Whether `PlayerSeason.teamAbbr` names a real club/franchise for this sport. Tennis has
    /// no team — `teamAbbr` holds the player's country code instead (see `providers/seed.py`'s
    /// `load_tennis` docstring), so card UI should render a country flag in the logo slot rather
    /// than attempting a team lookup/logo fetch that can never resolve.
    var hasTeams: Bool { self != .tennis }

    /// ESPN CDN league slug used for team-logo lookups; nil for teamless sports (tennis).
    /// Each sport MUST map to its own slug — sharing one (e.g. defaulting non-NFL to "nba")
    /// silently pulls the wrong league's crest for shared city codes (MLB "HOU" → the NBA
    /// Rockets instead of the Astros).
    var espnLeagueSlug: String? {
        switch self {
        case .nfl: return "nfl"
        case .nba: return "nba"
        case .baseball: return "mlb"
        case .soccer: return "soccer"
        case .tennis: return nil
        }
    }

    /// ESPN keys soccer crests by numeric team id, not the club abbreviation our catalog
    /// carries, so soccer abbreviations must be translated (US-league logos resolve directly
    /// from the lowercased abbreviation). Covers every club currently in the catalog.
    private static let soccerESPNTeamID: [String: String] = [
        "AVL": "362", "BAY": "132", "BUR": "379", "CHE": "363", "FCB": "83",
        "LIV": "364", "MCI": "382", "MUN": "360", "PSG": "160", "RMA": "86", "TOT": "367",
    ]

    /// Team-crest URL on the ESPN CDN for a club abbreviation, or nil when the sport is
    /// teamless, the abbreviation is empty, or (soccer only) the club isn't mapped. Callers
    /// render a neutral fallback on nil rather than a broken image.
    func teamLogoURL(forAbbr abbr: String) -> URL? {
        guard let league = espnLeagueSlug, !abbr.isEmpty else { return nil }
        let key: String
        if self == .soccer {
            guard let id = Sport.soccerESPNTeamID[abbr.uppercased()] else { return nil }
            key = id
        } else {
            key = abbr.lowercased()
        }
        return URL(string: "https://a.espncdn.com/i/teamlogos/\(league)/500/\(key).png")
    }
}

/// Home-screen sport filter — "All" plus each concrete sport.
enum SportFilter: String, CaseIterable, Identifiable {
    case all
    case nfl
    case nba
    case baseball
    case soccer
    case tennis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .nfl: return "NFL"
        case .nba: return "NBA"
        case .baseball: return "MLB"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        }
    }

    /// Whether a puzzle of the given sport should be shown under this filter.
    func includes(_ sport: Sport) -> Bool {
        switch self {
        case .all: return true
        case .nfl: return sport == .nfl
        case .nba: return sport == .nba
        case .baseball: return sport == .baseball
        case .soccer: return sport == .soccer
        case .tennis: return sport == .tennis
        }
    }

    /// The concrete sport this filter pins to, or nil for `.all`.
    var sport: Sport? {
        switch self {
        case .all: return nil
        case .nfl: return .nfl
        case .nba: return .nba
        case .baseball: return .baseball
        case .soccer: return .soccer
        case .tennis: return .tennis
        }
    }
}
