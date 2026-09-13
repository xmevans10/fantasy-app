import XCTest
@testable import BallIQ

@MainActor
final class DailyBoardFetchTests: XCTestCase {
    private let formats = ["keep4", "whoami", "journeyman"]

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DiskCache.directoryOverride = dir
    }

    override func tearDown() {
        if let dir = DiskCache.directoryOverride { try? FileManager.default.removeItem(at: dir) }
        DiskCache.directoryOverride = nil
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func repository() -> RemotePuzzleRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return RemotePuzzleRepository(client: SupabaseClient(
            config: SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "test"),
            session: URLSession(configuration: configuration)))
    }

    private func row(_ format: String, id: String, date: Date) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "\(format)_puzzles", withExtension: "json"))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var content = try XCTUnwrap(objects.first(where: { $0["sport"] as? String == "nfl" }))
        content["id"] = id
        return ["content": content, "active_date": PuzzleStore.localDayString(date)]
    }

    private func response(_ req: URLRequest, rows: [[String: Any]]) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         try! JSONSerialization.data(withJSONObject: rows))
    }

    private func pick(_ format: String, repo: RemotePuzzleRepository, date: Date) async -> (String?, Bool?) {
        switch format {
        case "keep4":
            let p = await repo.keep4Puzzle(for: .nfl, date: date)
            return (p?.content.id, p?.isCanonicalToday)
        case "whoami":
            let p = await repo.whoAmIPuzzle(for: .nfl, date: date)
            return (p?.content.id, p?.isCanonicalToday)
        default:
            let p = await repo.journeymanPuzzle(for: .nfl, date: date)
            return (p?.content.id, p?.isCanonicalToday)
        }
    }

    func testEveryFormatUsesBoundedReadAndSurvivesOfflineMidnight() async throws {
        let date = Date()
        let next = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        for format in formats {
            let rows = try [row(format, id: "today", date: date), row(format, id: "tomorrow", date: next)]
            var requests = 0
            MockURLProtocol.handler = { req in
                requests += 1
                let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertTrue(items.contains(URLQueryItem(name: "limit", value: "2")))
                XCTAssertTrue(items.contains(URLQueryItem(name: "sport", value: "eq.nfl")))
                XCTAssertTrue(items.contains(URLQueryItem(name: "active_date", value: "gte.\(PuzzleStore.localDayString(date))")))
                XCTAssertTrue(items.contains(URLQueryItem(name: "active_date", value: "lte.\(PuzzleStore.localDayString(next))")))
                return self.response(req, rows: rows)
            }
            let first = await pick(format, repo: repository(), date: date)
            XCTAssertEqual(first.0, "today")
            XCTAssertEqual(first.1, true)
            XCTAssertEqual(requests, 1)
            MockURLProtocol.handler = { _ in
                XCTFail("Same day and midnight restart must read disk without network")
                return (HTTPURLResponse(url: URL(string: "https://demo.supabase.co")!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            let warm = await pick(format, repo: repository(), date: date)
            let midnight = await pick(format, repo: repository(), date: next)
            XCTAssertEqual(warm.0, "today")
            XCTAssertEqual(midnight.0, "tomorrow")
            XCTAssertEqual(midnight.1, true)
        }
    }

    func testMissingDailyFallsBackWithoutClaimingTomorrowIsToday() async throws {
        let date = Date()
        let next = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        let old = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        for format in formats {
            let future = try row(format, id: "future", date: next)
            let archive = try row(format, id: "archive", date: old)
            var requests = 0
            MockURLProtocol.handler = { req in
                requests += 1
                return self.response(req, rows: [requests == 1 ? future : archive])
            }
            let p = await pick(format, repo: repository(), date: date)
            XCTAssertEqual(p.0, "archive")
            XCTAssertEqual(p.1, false)
            XCTAssertEqual(requests, 2)
        }
    }

    func testDailyCacheDoesNotReplaceBrowseArchive() async throws {
        let date = Date()
        let daily = try row("keep4", id: "daily", date: date)
        let archive = try row("keep4", id: "archive", date: date)
        MockURLProtocol.handler = { req in
            let limited = req.url!.query!.contains("limit=2")
            return self.response(req, rows: limited ? [daily] : [daily, archive])
        }
        let repo = repository()
        _ = await repo.keep4Puzzle(for: .nfl, date: date)
        let all = await repo.allKeep4(for: .nfl)
        XCTAssertEqual(Set(all.map(\.id)), ["daily", "archive"])
    }

    func testConcurrentDailyReadsAreCoalesced() async throws {
        let date = Date()
        let row = try row("keep4", id: "daily", date: date)
        let count = Counter()
        MockURLProtocol.handler = { req in
            count.increment()
            Thread.sleep(forTimeInterval: 0.1)
            return self.response(req, rows: [row])
        }
        let repo = repository()
        async let a = repo.keep4Puzzle(for: .nfl, date: date)
        async let b = repo.keep4Puzzle(for: .nfl, date: date)
        let results = await [a, b]
        XCTAssertEqual(results.compactMap { $0 }.count, 2)
        XCTAssertEqual(count.value, 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
