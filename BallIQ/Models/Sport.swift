import SwiftUI

enum Sport: String, Codable, CaseIterable, Identifiable {
    case nfl
    case nba

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nfl: return "NFL"
        case .nba: return "NBA"
        }
    }

    var abbreviation: String { displayName }

    /// SF Symbol used in filter pills / format icons.
    var symbol: String {
        switch self {
        case .nfl: return "football.fill"
        case .nba: return "basketball.fill"
        }
    }
}

/// Home-screen sport filter — "All" plus each concrete sport.
enum SportFilter: String, CaseIterable, Identifiable {
    case all
    case nfl
    case nba

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .nfl: return "NFL"
        case .nba: return "NBA"
        }
    }

    /// Whether a puzzle of the given sport should be shown under this filter.
    func includes(_ sport: Sport) -> Bool {
        switch self {
        case .all: return true
        case .nfl: return sport == .nfl
        case .nba: return sport == .nba
        }
    }

    /// The concrete sport this filter pins to, or nil for `.all`.
    var sport: Sport? {
        switch self {
        case .all: return nil
        case .nfl: return .nfl
        case .nba: return .nba
        }
    }
}
