import XCTest
@testable import BallIQ

/// Covers `CommunityPuzzleRepository.feed`'s sport predicate — the same self-protection
/// `RemotePuzzleRepository.fetch` applies to the daily/archive "All" filter (see
/// `Sport.decodableFilterValue`'s doc comment). Community rows are USER-written, so an unknown
/// sport reaching this feed isn't a mint-time-gate question, it's live the moment a newer build's
/// player publishes — this file pins that the "All sports" feed (`sport == nil`) asks PostgREST
/// for only the sports this build can decode, rather than sending no predicate at all.
final class CommunityPuzzleRepositoryTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func respond(_ req: URLRequest, json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(json.utf8))
    }

    func testAllSportsFeedSendsTheDecodableSportPredicate() async throws {
        var query = ""
        MockURLProtocol.handler = { req in
            query = req.url?.query ?? ""
            return self.respond(req, json: "[]")
        }
        let repo = CommunityPuzzleRepository(client: makeClient())
        _ = try await repo.feed(format: "keep4", sport: nil, sort: .recent)

        XCTAssertTrue(query.contains("sport=\(Sport.decodableFilterValue)"),
                      "the nil-sport feed must self-protect like RemotePuzzleRepository.fetch: \(query)")
    }

    /// A concrete sport still filters to exactly that sport — the predicate above must not
    /// widen an already-scoped feed.
    func testConcreteSportFeedFiltersToThatSportOnly() async throws {
        var query = ""
        MockURLProtocol.handler = { req in
            query = req.url?.query ?? ""
            return self.respond(req, json: "[]")
        }
        let repo = CommunityPuzzleRepository(client: makeClient())
        _ = try await repo.feed(format: "keep4", sport: .nfl, sort: .recent)

        XCTAssertTrue(query.contains("sport=eq.nfl"), query)
        XCTAssertFalse(query.contains(Sport.decodableFilterValue), query)
    }
}
