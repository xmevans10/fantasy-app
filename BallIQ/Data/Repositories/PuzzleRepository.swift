import Foundation

/// A daily puzzle pick alongside whether it's actually *today's* canonical row (an
/// `active_date` match, minted by `tools/ingest/daily_puzzle.py`) or a modulo fallback that
/// merely stood in for it. Callers that render a "TODAY" freshness badge must gate on
/// `isCanonicalToday` — otherwise an archive puzzle picked by the day-of-year fallback reads
/// as if it were freshly minted for today, which it isn't.
struct DailyPick<T> {
    let content: T
    let isCanonicalToday: Bool
}

/// Source of daily puzzles. Async so the Milestone 2 `Remote*` (Supabase) impl is a drop-in.
protocol PuzzleRepository {
    func keep4Puzzle(for filter: SportFilter, date: Date) async -> DailyPick<Keep4Puzzle>?
    func whoAmIPuzzle(for filter: SportFilter, date: Date) async -> DailyPick<WhoAmIPuzzle>?
    /// The full pool (for the Browse/Archive surface), not just today's pick.
    func allKeep4(for filter: SportFilter) async -> [Keep4Puzzle]
    func allWhoAmI(for filter: SportFilter) async -> [WhoAmIPuzzle]
    /// The Grid (M5 Phase E) — server-generated only, no bundled offline fallback (it's
    /// Pro-gated content anyway; a signed-out/local-only session can't play it either way).
    func gridPuzzle(for filter: SportFilter, date: Date) async -> DailyPick<GridPuzzle>?
    /// A board picked at random from the sport's full minted pool, for the setup screen's
    /// "new random grid" — the one Grid entry point that isn't the daily. `excludingDate`
    /// drops today's canonical row so a re-roll can't just hand back the daily the player is
    /// already there to play (and, since practice runs award nothing, can't be used to preview
    /// it either). Nil when the pool holds nothing else — a real state today: baseball has one
    /// board ever minted, soccer three.
    func randomGridPuzzle(for filter: SportFilter, excludingDate: String?) async -> GridPuzzle?
    /// Sport-wide distinct player names for The Grid's guess typeahead. Deliberately
    /// sport-wide, never cell-scoped — a cell-filtered list would hand the player the answers.
    /// Empty when unavailable (local-only / offline): the Grid degrades to free-text entry.
    func playerNameIndex(for sport: Sport) async -> [String]
    /// The sport's player → (team, year) membership relation, from which the client generates its
    /// **own** practice boards (`GridLocalGenerator`) instead of re-serving the small minted pool.
    /// Nil when unavailable — practice then falls back to `randomGridPuzzle`.
    func gridMembershipIndex(for sport: Sport) async -> GridMembershipIndex?
    var availableSports: [Sport] { get }
}

extension PuzzleRepository {
    /// Default: no index (bundled/offline repos). Only `RemotePuzzleRepository` overrides it.
    func playerNameIndex(for sport: Sport) async -> [String] { [] }
    /// Default: no membership index, same as above — a local-only session has no catalog to
    /// build one from, and the Grid is server-only content there anyway.
    func gridMembershipIndex(for sport: Sport) async -> GridMembershipIndex? { nil }
    /// Default: no pool. Grid content is server-only (see `gridPuzzle`), so every local/
    /// bundled repo correctly has nothing to draw a random board from.
    func randomGridPuzzle(for filter: SportFilter, excludingDate: String?) async -> GridPuzzle? { nil }
}

/// Loads bundled JSON; resolves the daily puzzle deterministically by the local calendar day.
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

    func keep4Puzzle(for filter: SportFilter, date: Date) async -> DailyPick<Keep4Puzzle>? {
        pick(from: filtered(keep4, by: filter), date: date)
    }

    func whoAmIPuzzle(for filter: SportFilter, date: Date) async -> DailyPick<WhoAmIPuzzle>? {
        pick(from: filtered(whoami, by: filter), date: date)
    }

    func allKeep4(for filter: SportFilter) async -> [Keep4Puzzle] { filtered(keep4, by: filter) }
    func allWhoAmI(for filter: SportFilter) async -> [WhoAmIPuzzle] { filtered(whoami, by: filter) }

    /// No bundled Grid content in v1 (see protocol doc comment) — local-only sessions simply
    /// can't play it, same as any other Pro-only surface without a network connection.
    func gridPuzzle(for filter: SportFilter, date: Date) async -> DailyPick<GridPuzzle>? { nil }

    // MARK: - Helpers

    private func filtered<P>(_ pool: [P], by filter: SportFilter) -> [P] where P: SportScoped {
        guard let sport = filter.sport else { return pool }
        return pool.filter { $0.sport == sport }
    }

    /// Deterministic daily pick — same puzzle for everyone sharing a local calendar day
    /// (reuses `PuzzleStore` seeding). This IS the offline modulo path, never a genuinely-dated
    /// row, so it's always `isCanonicalToday: false` — a truthful label, not a regression.
    private func pick<P>(from pool: [P], date: Date) -> DailyPick<P>? {
        guard !pool.isEmpty else { return nil }
        return DailyPick(content: pool[PuzzleStore.dailyIndex(count: pool.count, date: date)],
                          isCanonicalToday: false)
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
