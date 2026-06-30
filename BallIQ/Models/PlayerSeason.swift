import Foundation

/// A single player-season "card" in a Keep4/Cut4 puzzle.
struct PlayerSeason: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let teamAbbr: String
    let seasonYear: Int
    /// Display stat lines, ordered. e.g. [("Rec Yds", "1,632"), ("TD", "17")].
    let stats: [StatLine]
    /// Hidden quality grade used to derive the true ranking. Higher = better.
    let grade: Double

    struct StatLine: Codable, Equatable, Hashable {
        let label: String
        let value: String
    }

    var subtitle: String { "\(teamAbbr) · \(seasonYear)" }
}
