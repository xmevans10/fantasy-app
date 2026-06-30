import Foundation

/// Per-sport rating + history. Async for the Milestone 2 remote swap.
protocol RatingRepository {
    func rating(for sport: Sport) async -> Int
    func history(for sport: Sport) async -> [RatingPoint]
    /// Apply a session result; persists the new rating + a history point.
    func apply(_ outcome: GameOutcome, date: Date) async -> RatingChange
}

/// UserDefaults-backed per-sport rating store.
final class LocalRatingRepository: RatingRepository {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func ratingKey(_ sport: Sport) -> String { "rating.\(sport.rawValue)" }
    private func historyKey(_ sport: Sport) -> String { "ratingHistory.\(sport.rawValue)" }

    func rating(for sport: Sport) async -> Int {
        let stored = defaults.integer(forKey: ratingKey(sport))
        return stored == 0 ? RatingEngine.startingRating : stored
    }

    /// Overwrite the cached rating (used by sync reconciliation).
    func setRating(_ rating: Int, for sport: Sport) {
        defaults.set(rating, forKey: ratingKey(sport))
    }

    func history(for sport: Sport) async -> [RatingPoint] {
        guard let data = defaults.data(forKey: historyKey(sport)),
              let points = try? JSONDecoder().decode([RatingPoint].self, from: data) else { return [] }
        return points
    }

    func apply(_ outcome: GameOutcome, date: Date) async -> RatingChange {
        let current = await rating(for: outcome.sport)
        let change = RatingEngine.apply(rating: current, outcome: outcome)

        defaults.set(change.new, forKey: ratingKey(outcome.sport))
        var points = await history(for: outcome.sport)
        points.append(RatingPoint(date: date, rating: change.new))
        if let data = try? JSONEncoder().encode(points) {
            defaults.set(data, forKey: historyKey(outcome.sport))
        }
        return change
    }
}
