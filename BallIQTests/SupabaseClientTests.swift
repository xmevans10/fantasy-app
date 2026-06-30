import XCTest
@testable import BallIQ

/// Captures requests and returns canned responses so the client can be tested without a network.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocolDidFinishLoading(self); return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StubToken: TokenProvider {
    var accessToken: String?
    init(_ t: String?) { accessToken = t }
}

/// A token that swaps to a fresh value on refresh, to exercise the 401 retry path.
private final class RefreshingToken: TokenProvider {
    var accessToken: String?
    private let refreshed: String?
    init(initial: String?, refreshed: String?) {
        self.accessToken = initial; self.refreshed = refreshed
    }
    func refreshIfNeeded() async { accessToken = refreshed }
}

/// Thread-safe log of the `Authorization` headers the mock server saw, in order.
private final class HeaderLog {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func append(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
}

private struct RatingRow: Decodable, Equatable {
    let userId: String
    let sport: String
    let rating: Int
}

final class SupabaseClientTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!,
                                        anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testRestRequestURLAndHeaders() {
        let client = makeClient()
        let req = client.restRequest(table: "ratings", query: [URLQueryItem(name: "select", value: "*")])
        XCTAssertEqual(req.url?.absoluteString, "https://demo.supabase.co/rest/v1/ratings?select=*")
        XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"), "ANON123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ANON123")
    }

    func testBearerUsesUserTokenWhenSignedIn() {
        let client = makeClient()
        let token = StubToken("USER_JWT")
        client.tokenProvider = token
        let req = client.restRequest(table: "progress")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer USER_JWT")
    }

    func testUpsertComposesPreferAndOnConflict() {
        let client = makeClient()
        let req = client.restRequest(table: "progress", method: "POST",
                                     query: [URLQueryItem(name: "on_conflict", value: "user_id")],
                                     body: Data("{}".utf8),
                                     prefer: "resolution=merge-duplicates,return=minimal")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=minimal")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(req.url?.absoluteString.contains("on_conflict=user_id") ?? false)
    }

    func testSelectDecodesSnakeCaseJSON() async throws {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"[{"user_id":"u1","sport":"nfl","rating":1200}]"#
            return (resp, Data(json.utf8))
        }
        let rows: [RatingRow] = try await makeClient().select("ratings")
        XCTAssertEqual(rows, [RatingRow(userId: "u1", sport: "nfl", rating: 1200)])
    }

    func testPerformRetriesOnceOn401WithRefreshedToken() async throws {
        let client = makeClient()
        let token = RefreshingToken(initial: "EXPIRED", refreshed: "FRESH")  // strong: tokenProvider is weak
        client.tokenProvider = token
        let seen = HeaderLog()
        MockURLProtocol.handler = { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            seen.append(auth)
            if auth == "Bearer EXPIRED" {   // stale JWT → 401, like an expired access token
                let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (resp, Data(#"{"message":"JWT expired"}"#.utf8))
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("[]".utf8))
        }
        let rows: [RatingRow] = try await client.select("ratings")
        XCTAssertEqual(rows, [])
        // Refreshed the token and retried exactly once with the fresh one.
        XCTAssertEqual(seen.values, ["Bearer EXPIRED", "Bearer FRESH"])
    }

    func testPerform401FallsBackToAnonKeyWhenRefreshSignsOut() async throws {
        let client = makeClient()
        // Refresh clears the token (as sign-out does) → retry uses the anon key for public reads.
        let token = RefreshingToken(initial: "EXPIRED", refreshed: nil)  // strong: tokenProvider is weak
        client.tokenProvider = token
        let seen = HeaderLog()
        MockURLProtocol.handler = { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            seen.append(auth)
            let status = auth == "Bearer EXPIRED" ? 401 : 200
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (resp, Data("[]".utf8))
        }
        let rows: [RatingRow] = try await client.select("ratings")
        XCTAssertEqual(rows, [])
        XCTAssertEqual(seen.values, ["Bearer EXPIRED", "Bearer ANON123"])
    }

    func testHTTPErrorIsMapped() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"message":"unauthorized"}"#.utf8))
        }
        do {
            let _: [RatingRow] = try await makeClient().select("ratings")
            XCTFail("Expected error")
        } catch let SupabaseError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("unauthorized"))
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
