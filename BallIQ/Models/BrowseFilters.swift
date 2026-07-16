import Foundation

/// Decade facet for the Browse archive, derived from real `PlayerSeason.seasonYear` data —
/// no structured decade field exists on a baked `Keep4Puzzle`, so this buckets from the actual
/// 8 player-seasons rather than parsing theme titles.
enum DecadeFilter: String, CaseIterable, Identifiable {
    case all
    case seventies = "1970s"
    case eighties = "1980s"
    case nineties = "1990s"
    case twoThousands = "2000s"
    case twentyTens = "2010s"
    case twentyTwenties = "2020s"

    var id: String { rawValue }
    var title: String { self == .all ? String(localized: "All decades") : rawValue }
}

/// Puzzle-depth facet for the Browse archive — wraps `PuzzleGrain` with an `.all` case so it
/// slots into the same `PrimeDropdown` shape as `DecadeFilter` and `SportFilter`.
enum GrainFilter: String, CaseIterable, Identifiable {
    case all
    case season
    case singleGame = "game"
    case career

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:        return String(localized: "All depths")
        case .season:     return PuzzleGrain.season.badgeLabel.capitalized
        case .singleGame: return PuzzleGrain.singleGame.badgeLabel.capitalized
        case .career:     return PuzzleGrain.career.badgeLabel.capitalized
        }
    }
}

enum BrowseFilters {
    /// Buckets a puzzle by the **median** year's decade among its player-seasons. Median (not
    /// "most common decade") is deterministic even on an evenly-split 8-player pool, and
    /// degrades gracefully for the deliberately era-mixed "all-time"/"era-adjusted" themes.
    static func decade(of puzzle: Keep4Puzzle) -> DecadeFilter {
        let years = puzzle.players.map(\.seasonYear).sorted()
        guard !years.isEmpty else { return .all }
        let median = years[years.count / 2]
        let bucket = (median / 10) * 10
        return DecadeFilter(rawValue: "\(bucket)s") ?? .all
    }

    static func matchesDecade(_ puzzle: Keep4Puzzle, filter: DecadeFilter) -> Bool {
        filter == .all || decade(of: puzzle) == filter
    }

    static func matchesGrain(_ puzzle: Keep4Puzzle, filter: GrainFilter) -> Bool {
        filter == .all || puzzle.puzzleGrain().rawValue == filter.rawValue
    }
}
