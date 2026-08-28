import XCTest
import SwiftUI
@testable import BallIQ

/// Cover for the guest-purchase claim path — the fix for `public.entitlements` sitting at 0 rows
/// while purchases were actually happening.
///
/// The hole: `appAccountToken` is the only link between an Apple transaction and a BallIQ
/// account, it can only be set at purchase time from an already-signed-in session, and Apple
/// echoes back its absence on every later notification for the life of the subscription. In
/// production on 2026-08-26, 19 of 25 `purchase_attempted` events were signed out — so the
/// webhook was dropping the majority of purchases permanently.
///
/// The fix deliberately does NOT gate purchase on sign-in (that would stand in front of 92% of
/// paywall traffic — 254 `paywall_viewed`, 21 signed in — to fix a problem the buyer doesn't
/// have). Instead the app sells to everyone and reconciles afterwards. These tests hold both
/// halves in place: the claim call has to actually go out with the right shape, and it must
/// never go out when there's nothing to claim.
@MainActor
final class EntitlementClaimTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!,
                                        anonKey: "ANON123")
    private let userID = "00000000-0000-0000-0000-0000000000aa"

    /// Thread-safe capture of everything the mock server was asked for.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func append(_ r: URLRequest) { lock.lock(); requests.append(r); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        var paths: [String] { all.compactMap { $0.url?.path } }
    }

    private var log = RequestLog()

    override func setUp() {
        super.setUp()
        log = RequestLog()
        let log = self.log
        MockURLProtocol.handler = { request in
            log.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"ok":true,"claimed":1,"refused":{},"unverified":0}"#.utf8))
        }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    private func makeContainer(signedIn: Bool) -> RepositoryContainer {
        let client = makeClient()
        let session = Session(accessToken: "user.access.token", refreshToken: "user-refresh",
                              expiresAt: Date().addingTimeInterval(3600), userID: userID)
        let auth = signedIn ? AuthService(client: nil, signedInAs: session) : AuthService(client: nil)
        client.tokenProvider = auth.tokenBox
        return RepositoryContainer(auth: auth, client: client,
                                   store: StoreService(fetchStub: { _ in [] }))
    }

    // MARK: - The wire contract
    //
    // Two encoders exist in this codebase and only one of them is right here. These pin the
    // shape from the Swift side so the Deno side can't drift away from it silently.

    /// `JSONEncoder.supabase` snake-cases keys, so the Swift field `signedTransactions` has to
    /// arrive as `signed_transactions` — which is the name `claim-entitlement/index.ts` reads.
    /// Getting this wrong is invisible in Swift and returns 400 on every single claim.
    func testClaimEntitlementBodyUsesTheWireNameTheFunctionReads() throws {
        struct Body: Encodable { let signedTransactions: [String] }
        let data = try JSONEncoder.supabase.encode(Body(signedTransactions: ["a.b.c"]))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["signed_transactions"],
                        "the function reads `signed_transactions`; a camelCase key 400s every claim")
        XCTAssertNil(json["signedTransactions"])
        XCTAssertEqual(json["signed_transactions"] as? [String], ["a.b.c"])
    }

    func testFunctionRequestTargetsTheFunctionsEndpoint() {
        let req = makeClient().functionRequest(name: "claim-entitlement", body: Data("{}".utf8))

        XCTAssertEqual(req.url?.absoluteString,
                       "https://demo.supabase.co/functions/v1/claim-entitlement")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// The whole security model of `claim-entitlement` is "the bearer token says who you are".
    /// If the request went out with the anon key, the function would resolve no user and refuse
    /// every claim — and the failure would look exactly like the bug being fixed.
    func testFunctionRequestSendsTheUsersTokenNotTheAnonKey() {
        let client = makeClient()
        let session = Session(accessToken: "user.access.token", refreshToken: "r",
                              expiresAt: Date().addingTimeInterval(3600), userID: userID)
        let auth = AuthService(client: nil, signedInAs: session)
        client.tokenProvider = auth.tokenBox

        let req = client.functionRequest(name: "claim-entitlement", body: nil)

        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer user.access.token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"), "ANON123",
                       "the apikey header still identifies the project")
    }

    // MARK: - When the claim runs, and when it must not

    /// A signed-out user has no account to bind a purchase to. Calling anyway would 401 on
    /// every launch and bury the real failures in noise.
    func testClaimIsSkippedEntirelyWhenSignedOut() async {
        let container = makeContainer(signedIn: false)

        await container.claimEntitlements(reason: "test")

        XCTAssertTrue(log.all.isEmpty, "signed out: nothing to claim, so nothing should be sent")
    }

    /// The common case for most users — signed in, never bought anything. The round trip would
    /// always return `claimed: 0`, so it shouldn't happen at all: this runs on every sign-in
    /// sync, and a pointless request on every launch is a real cost.
    func testClaimIsSkippedWhenThereAreNoTransactionsToClaim() async {
        let container = makeContainer(signedIn: true)

        await container.claimEntitlements(reason: "test")

        XCTAssertFalse(log.paths.contains("/functions/v1/claim-entitlement"),
                       "no transactions on this device, the claim must not be sent")
    }

    /// A failed claim is bookkeeping, not something the user did wrong: they already hold the
    /// entitlement via the on-device StoreKit read. It must never throw into the purchase path.
    func testAFailingClaimNeverThrows() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"db write failed"}"#.utf8))
        }
        let container = makeContainer(signedIn: true)

        // Must return normally. A throw here would propagate out of `purchase(_:)` and surface
        // as "Purchase failed" on a purchase that actually succeeded.
        await container.claimEntitlements(reason: "test")
    }

    /// `invokeFunction` has to decode the function's own response shape, not PostgREST's.
    func testInvokeFunctionRoundTripsTheFunctionResponse() async throws {
        struct Body: Encodable { let signedTransactions: [String] }
        struct Result: Decodable { let ok: Bool; let claimed: Int }
        let client = makeClient()

        let data = try await client.invokeFunction("claim-entitlement",
                                                   body: Body(signedTransactions: ["a.b.c"]))
        let result: Result = try client.decode(data)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.claimed, 1)
        XCTAssertEqual(log.paths, ["/functions/v1/claim-entitlement"])
    }
}
