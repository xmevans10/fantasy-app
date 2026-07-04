import Foundation

/// Pure summary stats derived from a sport's rating history, for the Stats tab.
struct StatsSummary: Equatable {
    let best: Int
    let netChange: Int
    let gamesPlayed: Int

    static let empty = StatsSummary(best: RatingEngine.startingRating, netChange: 0, gamesPlayed: 0)

    init(best: Int, netChange: Int, gamesPlayed: Int) {
        self.best = best
        self.netChange = netChange
        self.gamesPlayed = gamesPlayed
    }

    /// `history` is chronological (oldest first), as returned by `RatingRepository.history(for:)`.
    /// Net change is measured from the starting rating, since the first history point already
    /// reflects the outcome of the first game.
    init(history: [RatingPoint], currentRating: Int) {
        guard !history.isEmpty else {
            self = StatsSummary(best: currentRating, netChange: 0, gamesPlayed: 0)
            return
        }
        best = history.map(\.rating).max() ?? currentRating
        netChange = currentRating - RatingEngine.startingRating
        gamesPlayed = history.count
    }
}
