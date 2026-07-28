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

    /// Day-of-year in the device's local calendar day — the deterministic daily seed. Local
    /// (not UTC) so the fallback pick below rotates at the same local midnight the canonical
    /// `active_date` selection does; two different "today"s would make the daily appear to
    /// change at 5pm one day and midnight the next.
    static func localDayOfYear(_ date: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.ordinality(of: .day, in: .year, for: date) ?? 1
    }

    /// Content-unavailability fallback: a deterministic index into a pool given a count and
    /// date. NOT the definition of "today's puzzle" — that's `active_date` on the server row
    /// (see `RemotePuzzleRepository.pick`). This only stands in when no row is actually minted
    /// for today (offline, a missed ingest run, or a format with no dated rows yet), and
    /// callers must track that distinction (`DailyPick.isCanonicalToday`) rather than assume a
    /// modulo pick is fresh content. Seeded by the *local* day, so users sharing a timezone
    /// share the fallback pick and it rotates at their midnight.
    static func dailyIndex(count: Int, date: Date = Date()) -> Int {
        guard count > 0 else { return 0 }
        return (localDayOfYear(date) - 1) % count
    }

    /// The device's local calendar day as "yyyy-MM-dd" — THE day key for daily content. A new
    /// puzzle appears at the user's own midnight (the ingest pipeline mints `active_date` rows
    /// days ahead, so the row for any timezone's "today" already exists — see
    /// .github/workflows/daily-puzzle.yml). Forced Gregorian + POSIX locale: the string must
    /// byte-match Postgres `date` serialization, and a device set to a non-Gregorian calendar
    /// or non-Latin digits would otherwise render a day string no server row can ever equal.
    static func localDayString(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
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
