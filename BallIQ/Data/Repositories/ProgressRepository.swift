import Foundation

/// Persisted progression state (streak, XP, last-played day).
struct ProgressSnapshot: Equatable {
    var streak: Int = 0
    var xp: Int = 0
    var lastPlayedDay: String = ""   // "yyyy-MM-dd" in local time

    var level: Int { LevelCurve.level(forXP: xp) }
}

/// Streak / XP / level store. Async for the Milestone 2 remote swap.
protocol ProgressRepository {
    func load() async -> ProgressSnapshot
    /// Record a completed daily game, awarding XP and advancing the streak. Returns the new snapshot.
    func recordCompletion(awardingXP xp: Int, date: Date) async -> ProgressSnapshot
}

/// UserDefaults-backed. Reuses the v0 keys so existing installs don't reset on upgrade.
final class LocalProgressRepository: ProgressRepository {
    private let defaults: UserDefaults
    private enum Key {
        static let streak = "streakCount"
        static let lastPlayed = "lastPlayedDate"
        static let xp = "xp"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() async -> ProgressSnapshot {
        ProgressSnapshot(streak: defaults.integer(forKey: Key.streak),
                         xp: defaults.integer(forKey: Key.xp),
                         lastPlayedDay: defaults.string(forKey: Key.lastPlayed) ?? "")
    }

    /// Overwrite the cached snapshot (used by sync when the server is authoritative).
    func overwrite(_ snapshot: ProgressSnapshot) {
        defaults.set(snapshot.streak, forKey: Key.streak)
        defaults.set(snapshot.xp, forKey: Key.xp)
        defaults.set(snapshot.lastPlayedDay, forKey: Key.lastPlayed)
    }

    func recordCompletion(awardingXP xp: Int, date: Date) async -> ProgressSnapshot {
        var snap = await load()
        let today = Self.dayFormatter.string(from: date)

        if snap.lastPlayedDay != today {
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: date),
               snap.lastPlayedDay == Self.dayFormatter.string(from: yesterday) {
                snap.streak += 1
            } else {
                snap.streak = 1
            }
            snap.lastPlayedDay = today
        }
        snap.xp += xp

        defaults.set(snap.streak, forKey: Key.streak)
        defaults.set(snap.xp, forKey: Key.xp)
        defaults.set(snap.lastPlayedDay, forKey: Key.lastPlayed)
        return snap
    }
}

extension ProgressSnapshot {
    func hasPlayed(on date: Date = Date()) -> Bool {
        lastPlayedDay == LocalProgressRepository.dayString(date)
    }
}

extension LocalProgressRepository {
    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}
