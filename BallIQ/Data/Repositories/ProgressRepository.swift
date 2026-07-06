import Foundation

/// Persisted progression state (streak, XP, last-played day).
struct ProgressSnapshot: Equatable {
    var streak: Int = 0
    var xp: Int = 0
    var lastPlayedDay: String = ""   // "yyyy-MM-dd" in local time
    /// Which specific puzzles (by id) were completed today. Local-UI-only (not synced to the
    /// server — it's a same-device checkmark, not competitive state); always empty unless it was
    /// just populated for today, since `LocalProgressRepository.load()` day-gates it on read.
    /// Keyed by puzzle id (not just format) so a stale completion can't leak onto a different
    /// puzzle later served under the same daily slot.
    var completedPuzzleIDsToday: Set<String> = []

    var level: Int { LevelCurve.level(forXP: xp) }
}

/// Streak / XP / level store. Async for the Milestone 2 remote swap.
protocol ProgressRepository {
    func load() async -> ProgressSnapshot
    /// Record a completed daily game, awarding XP and advancing the streak. Returns the new snapshot.
    func recordCompletion(format: GameFormatKind, puzzleID: String, awardingXP xp: Int, date: Date) async -> ProgressSnapshot
}

/// UserDefaults-backed. Reuses the v0 keys so existing installs don't reset on upgrade.
final class LocalProgressRepository: ProgressRepository {
    private let defaults: UserDefaults
    private enum Key {
        static let streak = "streakCount"
        static let lastPlayed = "lastPlayedDate"
        static let xp = "xp"
        /// The day-string `completedCards` is valid for — a mismatch means "today" has no
        /// recorded completions yet, which is the entire day-rollover reset mechanism (no
        /// timer/cron needed, it's just read-time-relative).
        static let completedCardsDay = "completedCardsDay"
        static let completedCards = "completedCardsToday"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() async -> ProgressSnapshot {
        let today = Self.dayString(Date())
        let ids: Set<String> = defaults.string(forKey: Key.completedCardsDay) == today
            ? Set(defaults.stringArray(forKey: Key.completedCards) ?? [])
            : []
        return ProgressSnapshot(streak: defaults.integer(forKey: Key.streak),
                                xp: defaults.integer(forKey: Key.xp),
                                lastPlayedDay: defaults.string(forKey: Key.lastPlayed) ?? "",
                                completedPuzzleIDsToday: ids)
    }

    /// Overwrite the cached snapshot (used by sync when the server is authoritative). Per-card
    /// completion is local-UI-only and has no server opinion, so it's deliberately left untouched
    /// here — only streak/xp/lastPlayedDay are ever server-authoritative.
    func overwrite(_ snapshot: ProgressSnapshot) {
        defaults.set(snapshot.streak, forKey: Key.streak)
        defaults.set(snapshot.xp, forKey: Key.xp)
        defaults.set(snapshot.lastPlayedDay, forKey: Key.lastPlayed)
    }

    func recordCompletion(format: GameFormatKind, puzzleID: String, awardingXP xp: Int, date: Date) async -> ProgressSnapshot {
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
        snap.completedPuzzleIDsToday.insert(puzzleID)

        defaults.set(snap.streak, forKey: Key.streak)
        defaults.set(snap.xp, forKey: Key.xp)
        defaults.set(snap.lastPlayedDay, forKey: Key.lastPlayed)
        defaults.set(today, forKey: Key.completedCardsDay)
        defaults.set(Array(snap.completedPuzzleIDsToday), forKey: Key.completedCards)
        return snap
    }
}

extension ProgressSnapshot {
    func hasPlayed(on date: Date = Date()) -> Bool {
        lastPlayedDay == LocalProgressRepository.dayString(date)
    }
    /// Was this *specific* puzzle completed today (not "was anything played").
    func hasCompletedToday(puzzleID: String, on date: Date = Date()) -> Bool {
        lastPlayedDay == LocalProgressRepository.dayString(date) && completedPuzzleIDsToday.contains(puzzleID)
    }
}

extension LocalProgressRepository {
    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}
