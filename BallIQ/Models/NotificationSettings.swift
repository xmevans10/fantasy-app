import Foundation

/// Per-category push opt-out, mirrors `notification_settings`. A missing server row (lazy
/// creation) means "all on", so `.allEnabled` is also the default for a fresh load.
struct NotificationSettings: Codable, Equatable {
    var streakAtRisk = true
    var leaguePosition = true
    var versusChallenge = true
    var seasonEnd = true

    static let allEnabled = NotificationSettings()

    enum CodingKeys: String, CodingKey {
        case streakAtRisk = "streak_at_risk"
        case leaguePosition = "league_position"
        case versusChallenge = "versus_challenge"
        case seasonEnd = "season_end"
    }
}
