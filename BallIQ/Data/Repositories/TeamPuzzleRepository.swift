import Foundation

struct TeamPuzzle: Codable, Identifiable {
    let id: String
    let sport: String
    let teamAbbr: String
    let shelf: String
    let sortOrder: Int
    let isStarter: Bool
    let content: Keep4Puzzle
    enum CodingKeys: String, CodingKey {
        case id, sport, shelf, content
        case teamAbbr = "team_abbr", sortOrder = "sort_order", isStarter = "is_starter"
    }
}

struct TeamReward: Decodable {
    let awardedXP: Int
    let xp: Int
    let streak: Int
    let lastPlayedDay: String
    let correct: Int
}

/// A durable outbox for team completions. Guests earn locally; signed-in offline results
/// wait for the server to settle XP. The server's user+puzzle key handles cross-device retries.
@MainActor
final class TeamPuzzleRepository {
    struct Pending: Codable {
        let id: String
        let keepIDs: [String]
        let guest: Bool
    }
    static let key = "myTeams.progress.v1"
    struct State: Codable {
        var completed: Set<String> = []
        var pending: [Pending] = []
    }
    private let client: SupabaseClient?
    private let defaults: UserDefaults
    private(set) var state: State
    init(client: SupabaseClient?, defaults: UserDefaults = .standard) {
        self.client = client; self.defaults = defaults
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }
    func reset() { state = State(); defaults.removeObject(forKey: Self.key) }
    func save() { defaults.set(try? JSONEncoder().encode(state), forKey: Self.key) }
    func stage(id: String, keepIDs: [String], guest: Bool) {
        guard !state.completed.contains(id) else { return }
        state.completed.insert(id)
        state.pending.append(Pending(id: id, keepIDs: keepIDs.sorted(), guest: guest)); save()
    }
    func acknowledge(_ id: String) {
        state.pending.removeAll { $0.id == id }; save()
    }
    func mergeCompleted(_ ids: [String]) { state.completed.formUnion(ids); save() }
    func syncCompleted() async throws {
        guard let client else { return }
        struct Row: Decodable { let puzzleId: String }
        var offset = 0
        while true {
            let rows: [Row] = try await client.select("team_completions", query: [URLQueryItem(name: "select", value: "puzzle_id"), URLQueryItem(name: "order", value: "puzzle_id")], range: (offset, offset + 499))
            mergeCompleted(rows.map(\.puzzleId))
            if rows.count < 500 { break }; offset += 500
        }
    }
    func settle(_ pending: Pending) async throws -> TeamReward {
        guard let client else { throw SupabaseError.notConfigured }
        struct Args: Encodable {
            let pPuzzleId: String; let pKeepIds: [String]; let pDay: String; let pGuestMigration: Bool
        }
        let raw = try await client.rpc("complete_team_puzzle", args: Args(pPuzzleId: pending.id, pKeepIds: pending.keepIDs, pDay: LocalProgressRepository.dayString(Date()), pGuestMigration: pending.guest))
        let result = try JSONDecoder().decode(TeamReward.self, from: raw)
        acknowledge(pending.id)
        return result
    }
    static func bundled() -> [TeamPuzzle] {
        guard let url = Bundle.main.url(forResource: "team_puzzles", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TeamPuzzle].self, from: data)) ?? []
    }
    func load(sport: Sport, team: String) async throws -> [TeamPuzzle] {
        let local = Self.bundled().filter { $0.sport == sport.rawValue && $0.teamAbbr == team }
        guard let client else { return local }
        do {
            let rows: [TeamPuzzle] = try await client.select("team_puzzles", query: [
                URLQueryItem(name: "select", value: "id,sport,team_abbr,shelf,sort_order,is_starter,content"),
                URLQueryItem(name: "sport", value: "eq.\(sport.rawValue)"),
                URLQueryItem(name: "team_abbr", value: "eq.\(team)"),
                URLQueryItem(name: "order", value: "sort_order,id"),
                URLQueryItem(name: "limit", value: "100")
            ], decoder: JSONDecoder())
            return rows
        } catch {
            if !local.isEmpty { return local }
            throw error
        }
    }
}
