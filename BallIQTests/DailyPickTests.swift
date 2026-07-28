import XCTest
@testable import BallIQ

/// Covers the match/fallback distinction `DailyPick.isCanonicalToday` exists for (2026-07-20):
/// the TODAY badge must only show on a row actually minted for today's local calendar date,
/// never on a modulo-picked archive puzzle standing in for it. Network is faked with `MockURLProtocol`
/// (defined in `SupabaseClientTests.swift`), same as `DiskCacheTests`.
@MainActor
final class DailyPickTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        // Redirect DiskCache into a per-run temp directory — see DiskCacheTests for why this
        // matters (hosted tests otherwise plant fixtures in the real host app's caches).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyPickTests-\(UUID().uuidString)")
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

    /// A row whose `active_date` matches today's local day must win, and be flagged canonical —
    /// this is the exact case the TODAY badge is allowed to trust.
    func testRemoteRowMatchingTodayIsCanonical() async {
        let today = PuzzleStore.localDayString()
        MockURLProtocol.handler = { req in
            self.respond(req, status: 200, json: """
            [{"content":{"id":"old","theme":"T","sport":"nfl","players":[]},"active_date":null},
             {"content":{"id":"minted-today","theme":"T","sport":"nfl","players":[]},"active_date":"\(today)"}]
            """)
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        let pick = await repo.keep4Puzzle(for: .all, date: Date())

        XCTAssertEqual(pick?.content.id, "minted-today")
        XCTAssertEqual(pick?.isCanonicalToday, true)
    }

    /// No row's `active_date` matches today (e.g. a missed ingest run) — `pick()` must still
    /// return something (the modulo fallback over the ordered pool) but flag it NOT canonical,
    /// so the TODAY badge stays hidden on stale content.
    func testRemoteRowsWithNoTodayMatchFallsBackAndIsNotCanonical() async {
        MockURLProtocol.handler = { req in
            self.respond(req, status: 200, json: """
            [{"content":{"id":"old-1","theme":"T","sport":"nfl","players":[]},"active_date":"2020-01-01"}]
            """)
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        let pick = await repo.keep4Puzzle(for: .all, date: Date())

        XCTAssertEqual(pick?.content.id, "old-1")
        XCTAssertEqual(pick?.isCanonicalToday, false)
    }

    /// An empty remote table delegates to the bundled `LocalPuzzleRepository` fallback, which
    /// is itself always the offline modulo path — never canonical, regardless of date.
    func testEmptyRemoteTableFallsBackToLocalAndIsNotCanonical() async {
        MockURLProtocol.handler = { req in self.respond(req, status: 200, json: "[]") }
        let repo = RemotePuzzleRepository(client: makeClient())
        let pick = await repo.keep4Puzzle(for: .all, date: Date())

        XCTAssertNotNil(pick, "the bundled fallback should still produce a puzzle")
        XCTAssertEqual(pick?.isCanonicalToday, false)
    }

    /// The archive must never list a puzzle that hasn't dropped yet. Since the mint gained a
    /// 2-day lookahead (2026-07-28) the pool ALWAYS carries future-dated rows, so without this
    /// filter a Pro subscriber could open Browse and play tomorrow's daily today — spoiling
    /// the puzzle they'd be served tomorrow. Today's own row must still be present.
    func testArchiveExcludesPuzzlesMintedForFutureDays() async {
        let today = PuzzleStore.localDayString()
        let tomorrow = PuzzleStore.localDayString(Date().addingTimeInterval(24 * 3600))
        MockURLProtocol.handler = { req in
            self.respond(req, status: 200, json: """
            [{"content":{"id":"archive-old","theme":"T","sport":"nfl","players":[]},"active_date":"2020-01-01"},
             {"content":{"id":"undated","theme":"T","sport":"nfl","players":[]},"active_date":null},
             {"content":{"id":"today","theme":"T","sport":"nfl","players":[]},"active_date":"\(today)"},
             {"content":{"id":"tomorrow","theme":"T","sport":"nfl","players":[]},"active_date":"\(tomorrow)"}]
            """)
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        let ids = await repo.allKeep4(for: .all).map(\.id)

        XCTAssertFalse(ids.contains("tomorrow"), "an unreleased puzzle must never reach the archive")
        XCTAssertEqual(ids, ["archive-old", "undated", "today"])
    }

    /// The daily pick itself is unaffected by that filter — it reads the full pool, so a
    /// future-dated row sitting in the cache can never hide today's canonical row.
    func testFutureRowsDoNotDisturbTodaysPick() async {
        let today = PuzzleStore.localDayString()
        let tomorrow = PuzzleStore.localDayString(Date().addingTimeInterval(24 * 3600))
        MockURLProtocol.handler = { req in
            self.respond(req, status: 200, json: """
            [{"content":{"id":"tomorrow","theme":"T","sport":"nfl","players":[]},"active_date":"\(tomorrow)"},
             {"content":{"id":"today","theme":"T","sport":"nfl","players":[]},"active_date":"\(today)"}]
            """)
        }
        let repo = RemotePuzzleRepository(client: makeClient())
        let pick = await repo.keep4Puzzle(for: .all, date: Date())

        XCTAssertEqual(pick?.content.id, "today")
        XCTAssertEqual(pick?.isCanonicalToday, true)
    }

    /// `LocalPuzzleRepository` alone (the fully offline path) is always the modulo pick —
    /// `isCanonicalToday: false` there is a true label, not a regression to fix later.
    func testLocalRepositoryIsNeverCanonical() async {
        let local = LocalPuzzleRepository()
        let pick = await local.keep4Puzzle(for: .all, date: Date())

        XCTAssertNotNil(pick)
        XCTAssertEqual(pick?.isCanonicalToday, false)
    }
}
