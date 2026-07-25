import Foundation

/// UserDefaults-backed per-(season, sport) rating store for the 8-week rating ladder. Parallels
/// `LocalRatingRepository`, but keyed by season id so each season is a fresh row: a new season has
/// no stored value and seeds from the soft-reset snapshot on the first ranked game (no cross-season
/// reset to fight). Reuses the *same* pure `RatingEngine` as the all-time rating — no new Elo math.
/// `peak` is the high-water mark the end-of-season badge is derived from.
final class LocalSeasonRatingRepository {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func ratingKey(_ seasonID: Int, _ sport: Sport) -> String {
        "seasonRating.\(seasonID).\(sport.rawValue)"
    }
    private func peakKey(_ seasonID: Int, _ sport: Sport) -> String {
        "seasonPeak.\(seasonID).\(sport.rawValue)"
    }

    /// Whether this (season, sport) has ever been seeded locally.
    func hasStored(seasonID: Int, sport: Sport) -> Bool {
        defaults.object(forKey: ratingKey(seasonID, sport)) != nil
    }

    /// Current season rating, or `seed` if this season hasn't been played yet.
    func rating(seasonID: Int, sport: Sport, seed: Int) -> Int {
        hasStored(seasonID: seasonID, sport: sport)
            ? defaults.integer(forKey: ratingKey(seasonID, sport)) : seed
    }

    /// Peak season rating, or `seed` if unseeded.
    func peak(seasonID: Int, sport: Sport, seed: Int) -> Int {
        defaults.object(forKey: peakKey(seasonID, sport)) != nil
            ? defaults.integer(forKey: peakKey(seasonID, sport)) : seed
    }

    /// Overwrite the cached season rating + peak (used by sync reconciliation — server wins).
    func setRating(_ rating: Int, peak: Int, seasonID: Int, sport: Sport) {
        defaults.set(rating, forKey: ratingKey(seasonID, sport))
        defaults.set(peak, forKey: peakKey(seasonID, sport))
    }

    /// Apply a session result to the season ladder. Seeds from `seed` on first play of the season,
    /// then runs the same Elo delta as the all-time rating and advances the peak.
    @discardableResult
    func apply(_ outcome: GameOutcome, seasonID: Int, seed: Int, date: Date) -> RatingChange {
        let base = rating(seasonID: seasonID, sport: outcome.sport, seed: seed)
        let change = RatingEngine.apply(rating: base, outcome: outcome)
        let newPeak = max(peak(seasonID: seasonID, sport: outcome.sport, seed: seed), change.new)
        setRating(change.new, peak: newPeak, seasonID: seasonID, sport: outcome.sport)
        return change
    }
}
