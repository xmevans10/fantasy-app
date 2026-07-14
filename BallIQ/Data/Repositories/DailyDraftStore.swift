import Foundation

/// UserDefaults-backed persistence for Daily Draft mode's daily score — local-only
/// (arcade session state, not synced), mirroring `LocalOverUnderStore`'s shape. Only the
/// FIRST Daily Draft completion of a UTC day becomes "official" (what a future leaderboard,
/// backlog #5, will eventually read); a replay that same day still earns XP via the normal
/// `RepositoryContainer.complete` call (Draft & Spin is always `ranked: false` regardless of
/// mode), but must never clobber the locked-in score with a luckier rerun.
final class DailyDraftStore {
    private let defaults: UserDefaults
    private enum Key {
        static func result(_ day: String) -> String { "dailyDraftResult_\(day)" }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A day's locked-in Daily Draft outcome — enough to render the result screen's "today's
    /// Daily Draft" framing and (eventually, backlog #5) a leaderboard row.
    struct StoredResult: Codable, Equatable {
        let sport: String
        let wins: Int
        let losses: Int
        let totalPoints: Int
        let outcome: String
    }

    func officialResult(for day: String) -> StoredResult? {
        guard let data = defaults.data(forKey: Key.result(day)) else { return nil }
        return try? JSONDecoder().decode(StoredResult.self, from: data)
    }

    func hasCompletedDailyDraft(for day: String) -> Bool { officialResult(for: day) != nil }

    /// Records `result` as `day`'s official score iff none exists yet. Returns whether this
    /// call became the official score — `false` means a replay arrived after the day's score
    /// was already locked in, and the caller should present it as XP-only practice.
    @discardableResult
    func recordIfFirst(sport: Sport, result: DraftSpinResult, day: String) -> Bool {
        guard officialResult(for: day) == nil else { return false }
        let stored = StoredResult(sport: sport.rawValue, wins: result.wins, losses: result.losses,
                                   totalPoints: result.totalPoints, outcome: result.outcome.rawValue)
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        defaults.set(data, forKey: Key.result(day))
        return true
    }
}
