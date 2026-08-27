import Foundation

/// The placement window: a new player's first few **rated** boards do not move their rating.
///
/// **Why it exists.** `RatingEngine.startingRating` is 1000, which is the exact first point of
/// Silver (`Tier.silver` is `1000...1199`, `Tier.bronze` is `0...999`), and
/// `RatingEngine.expectedPerformance` puts break-even at 50% on a blind eight-card sort. So the
/// median first-timer lost rating and was visibly demoted a tier by their first ever game.
/// Measured on a cold install: 2 of 8 correct, −10, Silver → Bronze — a red number as the very
/// first thing the progression system ever showed them.
///
/// **Why it is a separate type rather than four lines inside `complete()`.** The rule has a
/// feedback loop in it, and a feedback loop is exactly the kind of thing that must be testable
/// without a database. See `recordedRanked` for the trap.
enum RatingPlacement {

    /// Rated boards before the rating starts counting. Three is the familiar convention, and long
    /// enough that one unlucky board cannot define a new player's tier.
    static let games = 3

    /// Whether this session should actually move the rating.
    ///
    /// `ratedGamesBefore` counts **rated** rows already in the career log, excluding this
    /// session. Anything already unranked — Puzzle Blitz, community puzzles, archive replays,
    /// duels — must not be counted: a player who opened Blitz first would otherwise burn all
    /// three protected games on boards that were never going to move their rating, then meet
    /// their first real daily unprotected, which is the exact inversion of the intent.
    static func appliesRating(ranked: Bool, ratedGamesBefore: Int) -> Bool {
        ranked && !isInPlacement(ratedGames: ratedGamesBefore)
    }

    /// 🔴 **What must be written to `GameResult.ranked` — always the caller's own `ranked`.**
    ///
    /// This is deliberately an identity function, and it is a named function precisely so that
    /// the reason survives. The placement counter reads `GameResult.ranked`. If the row were
    /// instead stamped with `appliesRating(...)`, the counter would be reading the field the rule
    /// writes: it could only be incremented by a row the rule refuses to create, so the count
    /// would sit at zero forever, placement would never end, and **the rating would stop moving
    /// for every player, permanently**.
    ///
    /// The invariant, stated once: *the counter must be orthogonal to the field the rule writes.*
    /// `ranked` records whether the board was a **rated surface**; `appliesRating` decides
    /// whether rating moves **this time**. They are different questions and must stay different
    /// values. Locked by `RatingPlacementTests.testTheWindowTerminates`.
    static func recordedRanked(ranked: Bool) -> Bool { ranked }

    static func isInPlacement(ratedGames: Int) -> Bool { ratedGames < games }

    /// Rated boards still owed before the rating counts. `0` once placement is over.
    static func remaining(ratedGames: Int) -> Int { max(0, games - ratedGames) }

    /// Which placement game has just been finished, for "N of 3" on a result screen. Clamped, so
    /// an unranked board — which consumes no slot — can never render "0 of 3" or "4 of 3".
    static func index(ratedGames: Int) -> Int { min(max(ratedGames, 1), games) }
}
