import XCTest
@testable import BallIQ

/// Covers the setup screen's "new random grid" fetch (2026-07-27). The load-bearing property
/// isn't "a board comes back" — it's that the board arrives via the `random_grid_puzzle` RPC
/// rather than by downloading the sport's whole pool and picking client-side. NFL board content
/// averages 64 KB (cells carry 149-425 answer names), so a client-side pick would grow the
/// payload linearly with the pool, and deepening the pool is the whole plan for making "random"
/// feel random. If someone later "simplifies" this back to `fetch` + `randomElement()`, the
/// endpoint assertion here is what catches it.
///
/// Network is faked with `MockURLProtocol` (defined in `SupabaseClientTests.swift`), same as
/// `DailyPickTests`.
@MainActor
final class RandomGridPuzzleTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RandomGridPuzzleTests-\(UUID().uuidString)")
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

    private func respond(_ req: URLRequest, status: Int, json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    /// A single v2 board, as the RPC returns it — one JSON object, not an array of rows.
    private let boardJSON = """
    {"sport":"nfl","archetype":"teams-x-teams",
     "rows":[{"kind":"team","label":"MIA","abbr":"MIA"},
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

    /// The whole point of the RPC: one board, one row, via `/rest/v1/rpc/random_grid_puzzle` —
    /// NOT a `/rest/v1/puzzles` table read that would pull every board for the sport.
    func testFetchesViaRPCAndNotTheWholePool() async {
        var requestedPaths: [String] = []
        MockURLProtocol.handler = { req in
            requestedPaths.append(req.url?.path ?? "")
            return self.respond(req, status: 200, json: self.boardJSON)
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        _ = await repo.randomGridPuzzle(for: .nfl, excludingDate: "2026-07-27")

        XCTAssertEqual(requestedPaths, ["/rest/v1/rpc/random_grid_puzzle"],
                       "a random board must cost one RPC row, not a full-pool table read")
    }

    /// Board content is camelCase (it mirrors `grid.to_content`'s JSON exactly). Decoding it
    /// with the shared snake_case `JSONDecoder.supabase` silently yields nil, which would look
    /// like an empty pool rather than a decode bug — so pin the decoded shape, not just non-nil.
    func testDecodesV2BoardContent() async {
        MockURLProtocol.handler = { req in self.respond(req, status: 200, json: self.boardJSON) }
        let repo = RemotePuzzleRepository(client: makeClient())
        let board = await repo.randomGridPuzzle(for: .nfl, excludingDate: nil)

        XCTAssertEqual(board?.archetype, "teams-x-teams")
        XCTAssertEqual(board?.rows.count, 3)
        XCTAssertEqual(board?.cols.count, 3)
        XCTAssertEqual(board?.cells.count, 9)
        XCTAssertEqual(board?.rows.first?.kind, .team)
        XCTAssertEqual(board?.cols.first?.label, "CAR")
    }

    /// An exhausted pool is a real state, not an error: the RPC returns SQL NULL when the sport
    /// has no board other than today's. Baseball has exactly one board ever minted, so excluding
    /// today's leaves nothing — this must come back nil rather than throwing or hanging.
    func testExhaustedPoolReturnsNil() async {
        MockURLProtocol.handler = { req in self.respond(req, status: 200, json: "null") }
        let repo = RemotePuzzleRepository(client: makeClient())
        let board = await repo.randomGridPuzzle(for: .baseball, excludingDate: "2026-07-27")

        XCTAssertNil(board)
    }

    /// `.all` carries no concrete sport. The daily path has a documented bug history here
    /// (fetching every sport's row and silently picking whichever sorts first), so the random
    /// path refuses rather than guessing a sport.
    func testAllFilterReturnsNilWithoutCallingTheNetwork() async {
        var called = false
        MockURLProtocol.handler = { req in
            called = true
            return self.respond(req, status: 200, json: self.boardJSON)
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        let board = await repo.randomGridPuzzle(for: .all, excludingDate: nil)

        XCTAssertNil(board)
        XCTAssertFalse(called, "`.all` has no sport to randomise within — don't ask the server")
    }

    /// Grid content is server-only (no bundled offline fallback), so every local repo correctly
    /// has nothing to draw a random board from. This is the protocol default doing its job.
    func testLocalRepositoryHasNoRandomBoard() async {
        let local = LocalPuzzleRepository()
        let board = await local.randomGridPuzzle(for: .nfl, excludingDate: nil)

        XCTAssertNil(board)
    }
}
