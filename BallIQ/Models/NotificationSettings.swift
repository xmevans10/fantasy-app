import Foundation

/// Per-category push opt-out, mirrors `notification_settings`. A missing server row (lazy
/// creation) means "all on", so `.allEnabled` is also the default for a fresh load.
struct NotificationSettings: Codable, Equatable {
    var streakAtRisk = true
    var leaguePosition = true
    var versusChallenge = true
    var seasonEnd = true
    var friendRequest = true
    var dailyDrop = true

    static let allEnabled = NotificationSettings()
}
