import Foundation

/// A daily Keep4/Cut4 puzzle: 8 player-seasons, sort the top 4 (Keep) vs bottom 4 (Cut).
struct Keep4Puzzle: Identifiable, Codable, Equatable {
    let id: String
    let theme: String
    let sport: Sport
    let players: [PlayerSeason]   // exactly 8

    /// Player ids that belong in the correct Keep pile (the 4 highest grades).
    var correctKeepIDs: Set<String> {
        let topFour = players.sorted { $0.grade > $1.grade }.prefix(4)
        return Set(topFour.map(\.id))
    }
}

enum Pile: String {
    case keep
    case cut
}

/// Keep4/Cut4 difficulty mode. Hard hides stats — pure memory (brief).
enum Keep4Mode: String, CaseIterable {
    case normal
    case hard

    var title: String { self == .normal ? "Normal" : "Hard" }
    var formatKind: GameFormatKind { self == .normal ? .keep4Normal : .keep4Hard }
}

/// Pure scoring for a completed Keep4/Cut4 attempt.
enum Keep4Scoring {
    static let pointsPerCorrect = 250   // max 2000 across 8 cards
    static let perfectBonus = 1000

    struct Result: Equatable {
        let correctCount: Int           // 0...8
        let isPerfect: Bool
        let total: Int
        /// Per-player correctness, keyed by player id.
        let correctness: [String: Bool]
    }

    /// `placement` maps each player id to the pile the user dropped it in.
    static func score(puzzle: Keep4Puzzle, placement: [String: Pile]) -> Result {
        let correctKeep = puzzle.correctKeepIDs
        var correctness: [String: Bool] = [:]
        var correctCount = 0

        for player in puzzle.players {
            let shouldKeep = correctKeep.contains(player.id)
            let placed = placement[player.id]
            let isCorrect = (placed == .keep && shouldKeep) || (placed == .cut && !shouldKeep)
            correctness[player.id] = isCorrect
            if isCorrect { correctCount += 1 }
        }

        let isPerfect = correctCount == puzzle.players.count
        let total = correctCount * pointsPerCorrect + (isPerfect ? perfectBonus : 0)
        return Result(correctCount: correctCount, isPerfect: isPerfect,
                      total: total, correctness: correctness)
    }
}
