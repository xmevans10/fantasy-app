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
