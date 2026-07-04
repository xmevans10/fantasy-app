import Foundation

/// Which format/mode a session was — drives the rating difficulty weight (brief's ordering).
enum GameFormatKind: String, Codable, CaseIterable {
    case keep4Normal
    case keep4Hard
    case whoAmI

    /// Relative difficulty weight (Keep4 Normal < Keep4 Hard < Who Am I?). Grid will exceed these later.
    var ratingWeight: Double {
        switch self {
        case .keep4Normal: return 1.0
        case .keep4Hard:   return 1.4
        case .whoAmI:      return 1.6
        }
    }

    /// XP awarded on completion, before perfect/streak bonuses (brief: complete +100, hard +50 bonus).
    var baseXP: Int {
        switch self {
        case .keep4Normal: return 100
        case .keep4Hard:   return 150
        case .whoAmI:      return 100
        }
    }

    /// Which Home daily-card this format's completion should mark done. Keep4 Normal and Hard
    /// collapse to the same card — completing either clears the one K4C4 tile.
    var dailyCard: DailyCard {
        switch self {
        case .keep4Normal, .keep4Hard: return .keep4
        case .whoAmI: return .whoAmI
        }
    }
}

/// The two Home daily-game cards. Distinct from `GameFormatKind` (which also tracks Keep4's
/// Normal/Hard difficulty split for rating/XP) — completion tracking only cares which card.
enum DailyCard: String, Codable, CaseIterable {
    case keep4
    case whoAmI
}

/// The result of one completed session, fed to the rating engine.
struct GameOutcome: Equatable {
    let format: GameFormatKind
    let sport: Sport
    /// Normalized performance in 0...1 (Keep4 = accuracy w/ perfect boost; Who Am I? = clue efficiency).
    let performance: Double
}

/// Rating before/after a session.
struct RatingChange: Equatable {
    let old: Int
    let new: Int
    var delta: Int { new - old }
}

/// A point in a sport's rating history (for the future Stats graph).
struct RatingPoint: Codable, Equatable {
    let date: Date
    let rating: Int
}

/// Pure, deterministic Elo-style rating math.
enum RatingEngine {
    static let kFactor = 40.0
    static let startingRating = 1000

    /// Expected performance baseline rises with rating — better players must do better to gain.
    static func expectedPerformance(for rating: Int) -> Double {
        let e = 0.5 + Double(rating - startingRating) / 2000.0
        return min(max(e, 0.35), 0.85)
    }

    static func delta(rating: Int, outcome: GameOutcome) -> Int {
        let gap = outcome.performance - expectedPerformance(for: rating)
        return Int((kFactor * outcome.format.ratingWeight * gap).rounded())
    }

    /// Apply a session result, clamped so rating never drops below 0.
    static func apply(rating: Int, outcome: GameOutcome) -> RatingChange {
        let new = max(0, rating + delta(rating: rating, outcome: outcome))
        return RatingChange(old: rating, new: new)
    }
}
