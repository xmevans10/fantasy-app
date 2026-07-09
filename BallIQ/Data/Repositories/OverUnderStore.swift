import Foundation

/// UserDefaults-backed lives + high-score persistence for Over/Under — local-only (arcade
/// session state, not synced), mirroring `LocalProgressRepository`'s shape.
final class LocalOverUnderStore {
    private let defaults: UserDefaults
    private enum Key {
        static let livesCount = "overUnderLivesCount"
        static let livesLastLostAt = "overUnderLivesLastLostAt"
        static func highScore(_ sport: Sport) -> String { "overUnderHighScore_\(sport.rawValue)" }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Loads lives, applying any regen owed since the last read, and persists the regenerated
    /// value back immediately so `lastLostAt` doesn't drift on repeated reads within the hour.
    func loadLives(now: Date = Date()) -> LivesBank {
        let stored: LivesBank
        if defaults.object(forKey: Key.livesCount) == nil {
            stored = .initial
        } else {
            let count = defaults.integer(forKey: Key.livesCount)
            let lastLostAt = defaults.object(forKey: Key.livesLastLostAt) as? Date
            stored = LivesBank(count: count, lastLostAt: lastLostAt)
        }
        let regenerated = stored.regenerated(now: now)
        if regenerated != stored { saveLives(regenerated) }
        return regenerated
    }

    func saveLives(_ lives: LivesBank) {
        defaults.set(lives.count, forKey: Key.livesCount)
        if let lastLostAt = lives.lastLostAt {
            defaults.set(lastLostAt, forKey: Key.livesLastLostAt)
        } else {
            defaults.removeObject(forKey: Key.livesLastLostAt)
        }
    }

    func highScore(for sport: Sport) -> Int { defaults.integer(forKey: Key.highScore(sport)) }

    /// Returns true if `score` beat the previous high score (and persists it).
    @discardableResult
    func recordScore(_ score: Int, for sport: Sport) -> Bool {
        guard score > highScore(for: sport) else { return false }
        defaults.set(score, forKey: Key.highScore(sport))
        return true
    }
}
