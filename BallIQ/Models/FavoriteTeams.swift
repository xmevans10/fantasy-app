import Foundation

/// A user's one favorite team per sport, mirrors `profiles.favorite_teams`. Keyed by
/// `Sport.rawValue`, value is a `team_abbr` (see `PlayerSeasonCatalog.teams(for:)`). A
/// missing key means "no favorite picked" for that sport; tennis never gets a key
/// (`Sport.hasTeams == false`).
struct FavoriteTeams: Codable, Equatable {
    var teams: [String: String] = [:]

    static let empty = FavoriteTeams()

    func team(for sport: Sport) -> String? { teams[sport.rawValue] }

    mutating func setTeam(_ abbr: String?, for sport: Sport) {
        teams[sport.rawValue] = abbr
    }
}
