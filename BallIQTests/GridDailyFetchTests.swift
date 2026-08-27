import XCTest
@testable import BallIQ

/// Covers the daily Grid fetch (2026-08-27), the sibling of `RandomGridPuzzleTests`.
///
/// That file already established the rule for the *random* board — never download a sport's
/// whole grid pool to end up with one board — but the daily path kept doing exactly that, via
/// the shared `fetch` + `pick` the other three formats use. That's affordable for them (the
/// entire `keep4` table is 344 KB) and not for this one: grid cells carry every valid answer
/// name, so the NFL pool measured 3.5 MB on the wire against 14 KB for the single dated row, and
/// it grew with every board minted. It was paid on the first open of each new day, because the
/// pool cache only counts while it holds today's row.
///
/// So the assertions here are about the *request*, not just the answer. If someone later routes
/// the daily board back through `fetch`, `testDailyAsksForOneDatedRowNotThePool` fails.
@MainActor
final class GridDailyFetchTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridDailyFetchTests-\(UUID().uuidString)")
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

    private func respond(_ req: URLRequest, json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(json.utf8))
    }

    private func board(_ label: String) -> String {
        """
        {"sport":"nfl","archetype":"teams-x-teams",
         "rows":[{"kind":"team","label":"\(label)","abbr":"MIA"},
                 {"kind":"team","label":"SEA","abbr":"SEA"},
                 {"kind":"team","label":"LA","abbr":"LA"}],
         "cols":[{"kind":"team","label":"CAR","abbr":"CAR"},
                 {"kind":"team","label":"PIT","abbr":"PIT"},
                 {"kind":"team","label":"JAX","abbr":"JAX"}],
         "cells":[{"validAnswerIds":["1"],"validAnswerNames":["A"],"rarityStars":2},
                  {"validAnswerIds":["2"],"validAnswerNames":["B"],"rarityStars":2},
                  {"validAnswerIds":["3"],"validAnswerNames":["C"],"rarityStars":2},
                  {"validAnswerIds":["4"],"validAnswerNames":["D"],"rarityStars":1},
                  {"validAnswerIds":["5"],"validAnswerNames":["E"],"rarityStars":2},
                  {"validAnswerIds":["6"],"validAnswerNames":["F"],"rarityStars":2},
                  {"validAnswerIds":["7"],"validAnswerNames":["G"],"rarityStars":2},
                  {"validAnswerIds":["8"],"validAnswerNames":["H"],"rarityStars":3},
                  {"validAnswerIds":["9"],"validAnswerNames":["I"],"rarityStars":1}]}
        """
    }

    private func row(_ label: String, date: String?) -> String {
        let active = date.map { "\"\($0)\"" } ?? "null"
        return "{\"content\":\(board(label)),\"active_date\":\(active)}"
    }

    /// The load-bearing one: today's board comes from a single dated, limited row read — the
    /// query names `active_date`, and it never asks for the pool.
    func testDailyAsksForOneDatedRowNotThePool() async {
        let today = PuzzleStore.localDayString()
        var queries: [String] = []
        MockURLProtocol.handler = { req in
            queries.append(req.url?.query ?? "")
            return self.respond(req, json: "[\(self.row("MIA", date: today))]")
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        let pick = await repo.gridPuzzle(for: .nfl, date: Date())

        XCTAssertNotNil(pick)
        XCTAssertTrue(pick?.isCanonicalToday == true)
        XCTAssertEqual(queries.count, 1, "the dated row answered it; the pool must not be fetched too")
        let query = try! XCTUnwrap(queries.first)
        XCTAssertTrue(query.contains("active_date=eq.\(today)"), "must ask for the day: \(query)")
        XCTAssertTrue(query.contains("limit=1"), "must ask for one row: \(query)")
        // The pool read is `order=id` with no date predicate — its absence is the regression guard.
        XCTAssertFalse(query.contains("order=id"), "that's the whole-pool query: \(query)")
    }

    /// Second open of the same day is free. This is what the launch-time warm buys: the player
    /// taps into a board that is already on disk.
    func testSecondOpenOfTheSameDayHitsDisk() async {
        let today = PuzzleStore.localDayString()
        var requests = 0
        MockURLProtocol.handler = { req in
            requests += 1
            return self.respond(req, json: "[\(self.row("MIA", date: today))]")
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        _ = await repo.gridPuzzle(for: .nfl, date: Date())
        XCTAssertEqual(requests, 1)
        _ = await repo.gridPuzzle(for: .nfl, date: Date())
        XCTAssertEqual(requests, 1, "cached board for today must not refetch")
    }

    /// A day with no minted row still resolves, via the pool + modulo pick it always used — and
    /// honestly reports itself as non-canonical, which is what stops the result screen offering
    /// it as a challenge.
    func testFallsBackToThePoolWhenTheDayHasNoRow() async {
        var queries: [String] = []
        MockURLProtocol.handler = { req in
            queries.append(req.url?.query ?? "")
            // First call is the dated read: no row for today. Second is the pool.
            let json = queries.count == 1 ? "[]" : "[\(self.row("MIA", date: "2020-01-01"))]"
            return self.respond(req, json: json)
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        let pick = await repo.gridPuzzle(for: .nfl, date: Date())

        XCTAssertNotNil(pick, "an undated pool must still produce a board")
        XCTAssertFalse(pick?.isCanonicalToday ?? true, "a modulo pick is not today's canonical board")
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries[1].contains("order=id"), "fallback is the ordered pool read")
    }

    /// Nothing anywhere is still nil, not a crash and not a board from another day.
    func testNilWhenNeitherPathHasAnything() async {
        MockURLProtocol.handler = { req in self.respond(req, json: "[]") }
        let repo = RemotePuzzleRepository(client: makeClient())
        let pick = await repo.gridPuzzle(for: .nfl, date: Date())
        XCTAssertNil(pick)
    }

    /// The board now has three callers that can fire at once — the launch warm, the setup
    /// screen's warm, and the view's own load. They must join one request, not start three.
    /// Observed on device before this: two `network fetch` lines for one cold open.
    func testConcurrentCallersShareOneRequest() async {
        let today = PuzzleStore.localDayString()
        let counter = RequestCounter()
        MockURLProtocol.handler = { req in
            counter.bump()
            // Hold the response open long enough that the other callers are certainly waiting.
            Thread.sleep(forTimeInterval: 0.2)
            return self.respond(req, json: "[\(self.row("MIA", date: today))]")
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        async let a = repo.gridPuzzle(for: .nfl, date: Date())
        async let b = repo.gridPuzzle(for: .nfl, date: Date())
        async let c = repo.gridPuzzle(for: .nfl, date: Date())
        let picks = await [a, b, c]

        XCTAssertEqual(picks.compactMap { $0 }.count, 3, "every caller still gets the board")
        XCTAssertEqual(counter.value, 1, "three concurrent callers must share one request")
    }

    /// The typeahead index is 183 KB and the membership RPC ~591 KB / 10 s for NFL, so the same
    /// coalescing matters more there than it does for the 14 KB board.
    func testConcurrentNameIndexCallersShareOneRequest() async {
        let counter = RequestCounter()
        MockURLProtocol.handler = { req in
            counter.bump()
            Thread.sleep(forTimeInterval: 0.2)
            return self.respond(req, json: "[\"Kyler Murray\",\"Patrick Mahomes\"]")
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        async let a = repo.playerNameIndex(for: .nfl)
        async let b = repo.playerNameIndex(for: .nfl)
        let both = await [a, b]

        XCTAssertEqual(both.map(\.count), [2, 2])
        XCTAssertEqual(counter.value, 1)
    }
}

/// `MockURLProtocol.handler` runs off the main actor, so the counter it bumps needs its own
/// synchronization rather than a captured `var`.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
