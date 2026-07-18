import XCTest
@testable import BallIQ

/// Covers the disk-cache tier added to fix cold-launch latency (BALLIQ_SPEC §9 backlog #3):
/// `PlayerSeasonCatalog`'s arcade sample and `RemotePuzzleRepository`'s daily-puzzle rows both
/// sit on the same `DiskCache` primitive. Network is faked with `MockURLProtocol` (defined in
/// `SupabaseClientTests.swift`) so these run with zero real connectivity, same as that file.
@MainActor
final class DiskCacheTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        // Redirect every DiskCache read/write into a per-run temp directory — these tests
        // use production cache keys, and without this they'd plant fixtures in the host
        // app's real caches directory (which the next real launch would then serve).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCacheTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DiskCache.directoryOverride = dir
    }

    override func tearDown() {
        if let dir = DiskCache.directoryOverride {
            try? FileManager.default.removeItem(at: dir)
        }
        DiskCache.directoryOverride = nil
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func season(_ id: String, sport: Sport, year: Int = 2020) -> CatalogSeason {
        CatalogSeason(id: id, sport: sport, name: "Player \(id)", teamAbbr: "SF",
                      seasonYear: year, position: "QB", stats: ["passing_yards": 4000])
    }

    private func rowJSON(_ id: String, sport: Sport, year: Int) -> String {
        """
        {"id":"\(id)","sport":"\(sport.rawValue)","name":"Player \(id)","team_abbr":"SF",\
        "season_year":\(year),"position":"QB","stats":{"passing_yards":4000}}
        """
    }

    private func respond(_ req: URLRequest, status: Int, json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    /// Counts every request the mock handler actually saw — the network-skip assertions need
    /// this rather than just checking the returned rows, since a coincidentally-correct return
    /// value wouldn't prove the fetch was actually skipped.
    private final class RequestCounter {
        private(set) var count = 0
        func hit() { count += 1 }
    }

    // MARK: - PlayerSeasonCatalog arcade-sample cache

    /// A disk entry written "now" (well inside the 1-day TTL) must be served without ever
    /// touching the network — this is the entire point of the cache for a same-day relaunch.
    func testFreshDiskHitSkipsNetwork() async {
        let sport = Sport.nba   // dedicated sport per test to avoid cross-test file collisions
        let cached = [season("cached-1", sport: sport)]
        await DiskCache.write(cached, key: "arcade-pool-\(sport.rawValue)")

        let counter = RequestCounter()
        MockURLProtocol.handler = { req in counter.hit(); return self.respond(req, status: 500, json: "{}") }

        let catalog = PlayerSeasonCatalog(client: makeClient())
        let result = await catalog.draftSpinSample(for: sport)

        XCTAssertEqual(result.map(\.id), ["cached-1"])
        XCTAssertEqual(counter.count, 0, "a fresh disk hit must never call the network")
    }

    /// An entry older than the 1-day TTL is NOT fresh — it must trigger a real refetch (and the
    /// network's newer rows must win), not be served as if it were current.
    func testExpiredDiskEntryTriggersNetworkRefetch() async {
        let sport = Sport.baseball
        let stale = [season("old-1", sport: sport)]
        await DiskCache.write(stale, key: "arcade-pool-\(sport.rawValue)",
                              writtenAt: Date().addingTimeInterval(-25 * 60 * 60))   // 25h old > 24h TTL

        let counter = RequestCounter()
        MockURLProtocol.handler = { req in
            counter.hit()
            return self.respond(req, status: 200, json: "[\(self.rowJSON("fresh-1", sport: sport, year: 2024))]")
        }

        let catalog = PlayerSeasonCatalog(client: makeClient())
        let result = await catalog.draftSpinSample(for: sport)

        XCTAssertEqual(result.map(\.id), ["fresh-1"])
        XCTAssertEqual(counter.count, 1, "an expired entry must fall through to exactly one network fetch")
    }

    /// A network failure with a stale (expired) disk copy on hand must still serve that copy —
    /// real, if dated, data beats falling all the way back to the ~500-row bundle.
    func testStaleDiskEntryServedOnNetworkFailure() async {
        let sport = Sport.soccer
        let stale = [season("stale-1", sport: sport)]
        await DiskCache.write(stale, key: "arcade-pool-\(sport.rawValue)",
                              writtenAt: Date().addingTimeInterval(-25 * 60 * 60))

        MockURLProtocol.handler = { req in self.respond(req, status: 500, json: #"{"message":"down"}"#) }

        let catalog = PlayerSeasonCatalog(client: makeClient())
        let result = await catalog.draftSpinSample(for: sport)

        XCTAssertEqual(result.map(\.id), ["stale-1"])
    }

    /// The bundled offline fallback must never be written to disk as if it were remote data —
    /// otherwise one offline launch would poison every launch after it with trimmed sample data.
    func testBundledFallbackIsNotPersistedToDisk() async {
        let sport = Sport.tennis   // no pre-existing disk entry, and `client: nil` means
                                   // `fetchRemote` returns nil without any network attempt.
        let catalog = PlayerSeasonCatalog(client: nil)
        _ = await catalog.draftSpinSample(for: sport)

        let onDisk = await DiskCache.read([CatalogSeason].self, key: "arcade-pool-\(sport.rawValue)")
        XCTAssertNil(onDisk, "a bundled-fallback result must not be written to disk")
    }

    // MARK: - RemotePuzzleRepository daily-puzzle cache

    /// A same-UTC-day cache entry that CONTAINS today's dated row is fresh — no network.
    /// (Written-today alone is not enough; see the companion test below.)
    func testDailyPuzzleCacheServesSameDayWithTodaysRowWithoutNetwork() async throws {
        struct Row: Codable { let content: Keep4Puzzle; let activeDate: String?
            private enum CodingKeys: String, CodingKey { case content; case activeDate = "active_date" } }
        let puzzle = Keep4Puzzle(id: "p1", theme: "T", sport: .nfl, players: [])
        let today = PuzzleStore.todayUTCString()
        await DiskCache.write([Row(content: puzzle, activeDate: today)], key: "puzzles-keep4-all")

        let counter = RequestCounter()
        MockURLProtocol.handler = { req in counter.hit(); return self.respond(req, status: 500, json: "{}") }

        let repo = RemotePuzzleRepository(client: makeClient())
        let rows = await repo.allKeep4(for: .all)

        XCTAssertEqual(rows.map(\.id), ["p1"])
        XCTAssertEqual(counter.count, 0, "same-day cache holding today's row must never call the network")
    }

    /// A same-UTC-day cache entry WITHOUT today's dated row must refetch: it was written
    /// before the day's ingest minted the row, and serving it would pin the day to the modulo
    /// fallback (an old puzzle) until midnight UTC — hit live 2026-07-17 with the Grid.
    /// Network failure still falls back to the same-day cache rather than losing the pool.
    func testDailyPuzzleCacheWithoutTodaysRowRefetches() async throws {
        struct Row: Codable { let content: Keep4Puzzle; let activeDate: String?
            private enum CodingKeys: String, CodingKey { case content; case activeDate = "active_date" } }
        let preMint = Keep4Puzzle(id: "pre-mint", theme: "T", sport: .nfl, players: [])
        await DiskCache.write([Row(content: preMint, activeDate: nil)], key: "puzzles-keep4-all")

        let counter = RequestCounter()
        let today = PuzzleStore.todayUTCString()
        MockURLProtocol.handler = { req in
            counter.hit()
            return self.respond(req, status: 200,
                json: #"[{"content":{"id":"minted-today","theme":"T","sport":"nfl","players":[]},"active_date":"\#(today)"}]"#)
        }

        let repo = RemotePuzzleRepository(client: makeClient())
        let rows = await repo.allKeep4(for: .all)

        XCTAssertEqual(counter.count, 1, "cache without today's row must refetch")
        XCTAssertEqual(rows.map(\.id), ["minted-today"])
    }

    /// A cache entry from a previous UTC day is stale (not just old — a fresh row minted today
    /// wouldn't be in it at all) and must trigger a refetch rather than being served as-is.
    func testDailyPuzzleCacheRefetchesOnNewDay() async throws {
        struct Row: Codable { let content: Keep4Puzzle; let activeDate: String?
            private enum CodingKeys: String, CodingKey { case content; case activeDate = "active_date" } }
        let yesterday = Keep4Puzzle(id: "yesterday", theme: "T", sport: .nfl, players: [])
        await DiskCache.write([Row(content: yesterday, activeDate: nil)], key: "puzzles-keep4-all",
                              writtenAt: Date().addingTimeInterval(-25 * 60 * 60))

        let today = Keep4Puzzle(id: "today", theme: "T", sport: .nfl, players: [])
        let counter = RequestCounter()
        MockURLProtocol.handler = { req in
            counter.hit()
            let data = try! JSONEncoder().encode([Row(content: today, activeDate: nil)])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let repo = RemotePuzzleRepository(client: makeClient())
        let rows = await repo.allKeep4(for: .all)

        XCTAssertEqual(rows.map(\.id), ["today"])
        XCTAssertEqual(counter.count, 1)
    }
}
