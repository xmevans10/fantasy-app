import Foundation

/// Source of daily puzzles. Async so the Milestone 2 `Remote*` (Supabase) impl is a drop-in.
protocol PuzzleRepository {
    func keep4Puzzle(for filter: SportFilter, date: Date) async -> Keep4Puzzle?
    func whoAmIPuzzle(for filter: SportFilter, date: Date) async -> WhoAmIPuzzle?
    /// The full pool (for the Browse/Archive surface), not just today's pick.
    func allKeep4(for filter: SportFilter) async -> [Keep4Puzzle]
    func allWhoAmI(for filter: SportFilter) async -> [WhoAmIPuzzle]
    /// The Grid (M5 Phase E) — server-generated only, no bundled offline fallback (it's
    /// Pro-gated content anyway; a signed-out/local-only session can't play it either way).
    func gridPuzzle(for filter: SportFilter, date: Date) async -> GridPuzzle?
    var availableSports: [Sport] { get }
}

/// Loads bundled JSON; resolves the daily puzzle deterministically by UTC date.
final class LocalPuzzleRepository: PuzzleRepository {
    private let keep4: [Keep4Puzzle]
    private let whoami: [WhoAmIPuzzle]

    init() {
        // Reuse the existing Keep4 loader; load Who Am I? alongside.
        self.keep4 = PuzzleStore.shared.puzzles
        self.whoami = Self.loadBundle("whoami_puzzles")
    }

    var availableSports: [Sport] {
        Sport.allCases.filter { sport in
            keep4.contains { $0.sport == sport } || whoami.contains { $0.sport == sport }
        }
    }

    func keep4Puzzle(for filter: SportFilter, date: Date) async -> Keep4Puzzle? {
        pick(from: filtered(keep4, by: filter), date: date)
    }

    func whoAmIPuzzle(for filter: SportFilter, date: Date) async -> WhoAmIPuzzle? {
        pick(from: filtered(whoami, by: filter), date: date)
    }

    func allKeep4(for filter: SportFilter) async -> [Keep4Puzzle] { filtered(keep4, by: filter) }
    func allWhoAmI(for filter: SportFilter) async -> [WhoAmIPuzzle] { filtered(whoami, by: filter) }

    /// No bundled Grid content in v1 (see protocol doc comment) — local-only sessions simply
    /// can't play it, same as any other Pro-only surface without a network connection.
    func gridPuzzle(for filter: SportFilter, date: Date) async -> GridPuzzle? { nil }

    // MARK: - Helpers

    private func filtered<P>(_ pool: [P], by filter: SportFilter) -> [P] where P: SportScoped {
        guard let sport = filter.sport else { return pool }
        return pool.filter { $0.sport == sport }
    }

    /// Deterministic daily pick — same puzzle for everyone that day (reuses `PuzzleStore` seeding).
    private func pick<P>(from pool: [P], date: Date) -> P? {
        guard !pool.isEmpty else { return nil }
        return pool[PuzzleStore.dailyIndex(count: pool.count, date: date)]
    }

    private static func loadBundle<T: Decodable>(_ name: String) -> [T] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("\(name).json missing from bundle")
            return []
        }
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            assertionFailure("Failed to decode \(name).json: \(error)")
            return []
        }
    }
}

/// Lets the generic filter work across puzzle types.
protocol SportScoped { var sport: Sport { get } }
extension Keep4Puzzle: SportScoped {}
extension WhoAmIPuzzle: SportScoped {}
