import Foundation

/// Loads the bundled Keep4/Cut4 puzzles and resolves "today's" puzzle deterministically.
final class PuzzleStore {
    static let shared = PuzzleStore()

    let puzzles: [Keep4Puzzle]

    private init() {
        self.puzzles = Self.loadBundledPuzzles()
    }

    private static func loadBundledPuzzles() -> [Keep4Puzzle] {
        guard let url = Bundle.main.url(forResource: "keep4_puzzles", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("keep4_puzzles.json missing from bundle")
            return []
        }
        do {
            return try JSONDecoder().decode([Keep4Puzzle].self, from: data)
        } catch {
            assertionFailure("Failed to decode keep4_puzzles.json: \(error)")
            return []
        }
    }

    /// Day-of-year in UTC, used as the deterministic daily seed (brief: seed resolves at midnight UTC).
    static func dayOfYearUTC(_ date: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.ordinality(of: .day, in: .year, for: date) ?? 1
    }

    /// Deterministic index into a pool given a count and date — same for all users that day.
    static func dailyIndex(count: Int, date: Date = Date()) -> Int {
        guard count > 0 else { return 0 }
        return (dayOfYearUTC(date) - 1) % count
    }

    /// UTC calendar day as "yyyy-MM-dd" (matches Postgres `date` JSON serialization and the
    /// UTC day the ingest pipeline stamps `active_date` with). Used to find *the* puzzle
    /// minted for today, rather than a modulo pick that can land on any day's puzzle.
    static func todayUTCString(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter.string(from: date)
    }

    /// Today's puzzle for a given sport (falls back to the global daily puzzle).
    func todaysPuzzle(for sport: Sport? = nil, date: Date = Date()) -> Keep4Puzzle? {
        let pool = sport.map { s in puzzles.filter { $0.sport == s } } ?? puzzles
        guard !pool.isEmpty else { return nil }
        return pool[Self.dailyIndex(count: pool.count, date: date)]
    }

    /// All sports that have at least one puzzle.
    var availableSports: [Sport] {
        Sport.allCases.filter { sport in puzzles.contains { $0.sport == sport } }
    }
}
