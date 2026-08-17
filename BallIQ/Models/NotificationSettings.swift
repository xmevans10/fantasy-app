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
    /// The midday "your move" nudge and the evening recap — the two slots added 2026-08-13 to
    /// reach a three-a-day cadence. One switch for both, because to a player they are the same
    /// thing (the app nudging them about their own open business), and splitting them would be
    /// asking about plumbing rather than about what they'd actually want to turn off.
    var engagement = true

    static let allEnabled = NotificationSettings()
}
