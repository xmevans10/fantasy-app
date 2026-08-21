import XCTest
@testable import BallIQ

/// `LiveDuelState`'s decode, and the client's actual resilience story around it — see
/// `LiveDuelSessionResilienceTests` below for why "a malformed payload doesn't throw away the
/// whole duel" lives one layer up from the decoder itself.
final class LiveDuelStateDecodeTests: XCTestCase {

    /// The exact shape `versus_live_state` returns per M23 §3, both sides mid-race. Pins field
    /// names against the wire, not against Swift property names — `winnerID`'s capital `ID` in
    /// particular is the one this decoder's own doc comment calls out as the trap
    /// `.convertFromSnakeCase` would fall into (`winner_id` → `winnerId`, never matching).
    private let liveJSON = """
    {
      "mode": "live",
      "live_started_at": "2026-08-21T15:00:00Z",
      "server_now": "2026-08-21T15:01:12Z",
      "time_limit_seconds": 120,
      "status": "pending",
      "winner_id": null,
      "me": {"ready": true, "guesses": 2, "finished": false, "solved": false},
      "them": {"ready": true, "guesses": 1, "finished": false, "solved": false}
    }
    """

    func testDecodesTheExactPollShape() throws {
        let state = try JSONDecoder.supabaseExplicitKeys.decode(LiveDuelState.self,
                                                                 from: Data(liveJSON.utf8))
        XCTAssertEqual(state.status, "pending")
        XCTAssertNil(state.winnerID)
        XCTAssertEqual(state.timeLimitSeconds, 120)
        XCTAssertEqual(state.me.guesses, 2)
        XCTAssertEqual(state.them.guesses, 1)
        XCTAssertTrue(state.bothReady)
        XCTAssertNotNil(state.liveStartedAt)
        // `deadline` is `liveStartedAt + timeLimitSeconds` — the shared clock both boards read,
        // so a wrong offset here would desync the two players' displayed time.
        XCTAssertEqual(state.deadline, state.liveStartedAt?.addingTimeInterval(120))
    }

    /// A completed row with a winner — `winnerID`'s capital-`ID` decode, exercised on the branch
    /// where it's actually non-nil rather than the all-nil pending case above. A distinct literal
    /// rather than a string transform of `liveJSON`: both `"me"` and `"them"` share the substring
    /// `"solved": false}`, so a global find/replace on that string would have flipped both.
    func testDecodesAResolvedRowsWinnerID() throws {
        let json = """
        {
          "mode": "live",
          "live_started_at": "2026-08-21T15:00:00Z",
          "server_now": "2026-08-21T15:01:12Z",
          "time_limit_seconds": 120,
          "status": "completed",
          "winner_id": "user-a",
          "me": {"ready": true, "guesses": 1, "finished": true, "solved": true},
          "them": {"ready": true, "guesses": 3, "finished": false, "solved": false}
        }
        """
        let state = try JSONDecoder.supabaseExplicitKeys.decode(LiveDuelState.self,
                                                                 from: Data(json.utf8))
        XCTAssertEqual(state.winnerID, "user-a")
        XCTAssertEqual(state.status, "completed")
        XCTAssertTrue(state.me.solved)
        XCTAssertFalse(state.them.solved)
    }

    /// Before `live_started_at` is stamped (still in the ready handshake), the shared clock
    /// hasn't started — `deadline` has to say so with `nil` rather than a bogus "120 seconds
    /// from the Unix epoch", which is what a force-unwrap of a null `live_started_at` would
    /// otherwise produce further down the pipeline.
    func testDeadlineIsNilBeforeTheClockStarts() throws {
        let json = liveJSON.replacingOccurrences(
            of: #""live_started_at": "2026-08-21T15:00:00Z""#, with: #""live_started_at": null"#)
        let state = try JSONDecoder.supabaseExplicitKeys.decode(LiveDuelState.self,
                                                                 from: Data(json.utf8))
        XCTAssertNil(state.deadline)
    }

    /// A payload missing a required field (a genuinely malformed poll response — truncated body,
    /// a server error mid-response) throws rather than silently defaulting: `LiveDuelState` has
    /// no hand-rolled tolerant `init(from:)` the way `VersusChallenge` does, because unlike a
    /// `DiskCache`-persisted challenge row, a live poll is never cached across a schema change —
    /// it's fetched fresh every 1.5s. Pinned here so nobody "fixes" a throw here without also
    /// checking `LiveDuelSessionResilienceTests`, which is where the actual tolerance lives.
    func testAPayloadMissingARequiredFieldThrowsRatherThanSilentlyDefaulting() {
        let malformed = liveJSON.replacingOccurrences(of: #""time_limit_seconds": 120,"#, with: "")
        XCTAssertThrowsError(
            try JSONDecoder.supabaseExplicitKeys.decode(LiveDuelState.self, from: Data(malformed.utf8)))
    }
}

// MARK: - Mock transport

/// Captures the request and hands back a canned response — the same shape
/// `SupabaseClientTests.MockURLProtocol` uses; redeclared here as `LiveMockURLProtocol` instead
/// of reused because that one is `private` to its own file.
final class LiveMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = LiveMockURLProtocol.handler else {
            client?.urlProtocolDidFinishLoading(self); return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StubUserToken: TokenProvider {
    var accessToken: String?
    init(_ userID: String) { accessToken = userID }
}

private func makeClient(user: String) -> (SupabaseClient, StubUserToken) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [LiveMockURLProtocol.self]
    let client = SupabaseClient(config: SupabaseConfig(url: URL(string: "https://demo.supabase.co")!,
                                                        anonKey: "ANON"),
                                session: URLSession(configuration: cfg))
    let token = StubUserToken(user)   // kept alive by the caller — `tokenProvider` is weak
    client.tokenProvider = token
    return (client, token)
}

private extension URLRequest {
    /// `nil` for anything that isn't an RPC call (e.g. a plain table `select`).
    var rpcName: String? {
        guard let path = url?.path, let range = path.range(of: "/rpc/") else { return nil }
        return String(path[range.upperBound...])
    }
    /// **Reads `httpBodyStream`, not just `httpBody`, and that is load-bearing.** `URLSession`
    /// converts a POST body to a stream before `URLProtocol` ever sees the request, so
    /// `httpBody` is `nil` inside a mock for exactly the calls that carry arguments. Relying on
    /// it alone made every `p_guesses` read as 0 while the header-only `mark_versus_ready` kept
    /// working — so the handshake passed, the strips silently never ticked, and the failure
    /// looked like a bug in `LiveDuelSession` rather than in this helper.
    var jsonBody: [String: Any] {
        let data: Data? = httpBody ?? {
            guard let stream = httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[..<read])
            }
            return collected
        }()
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

/// `LiveDuelSession.poll()` is where a malformed/dropped response is actually absorbed — not
/// `LiveDuelState`'s decoder, which throws on purpose (see `LiveDuelStateDecodeTests` above).
/// This pins the behavior the milestone brief actually asked for: a bad poll costs one tick of
/// staleness, never the duel itself.
@MainActor
final class LiveDuelSessionResilienceTests: XCTestCase {
    override func tearDown() { LiveMockURLProtocol.handler = nil; super.tearDown() }

    /// A poll that comes back truncated/malformed (missing `them`, say — a server hiccup mid-
    /// response) must not clear a `state` the session already had, and must not crash the poll
    /// loop into stopping forever: the very next successful poll has to be believed again. If
    /// this regressed, one bad network blip would either wipe the opponent's strip back to
    /// nothing or freeze the board on stale data forever.
    func testAMalformedPollKeepsTheLastGoodStateAndRecoversOnTheNextTick() async {
        let (client, token) = makeClient(user: "userA")
        _ = token
        var callCount = 0
        LiveMockURLProtocol.handler = { req in
            callCount += 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if callCount == 1 {
                // A healthy first poll.
                let json = """
                {"mode":"live","live_started_at":"2026-08-21T15:00:00Z",
                 "server_now":"2026-08-21T15:00:05Z","time_limit_seconds":120,
                 "status":"pending","winner_id":null,
                 "me":{"ready":true,"guesses":1,"finished":false,"solved":false},
                 "them":{"ready":true,"guesses":0,"finished":false,"solved":false}}
                """
                return (resp, Data(json.utf8))
            } else if callCount == 2 {
                // Malformed: `them` missing entirely.
                let json = """
                {"mode":"live","live_started_at":"2026-08-21T15:00:00Z",
                 "server_now":"2026-08-21T15:00:07Z","time_limit_seconds":120,
                 "status":"pending","winner_id":null,
                 "me":{"ready":true,"guesses":1,"finished":false,"solved":false}}
                """
                return (resp, Data(json.utf8))
            } else {
                // Recovered.
                let json = """
                {"mode":"live","live_started_at":"2026-08-21T15:00:00Z",
                 "server_now":"2026-08-21T15:00:09Z","time_limit_seconds":120,
                 "status":"pending","winner_id":null,
                 "me":{"ready":true,"guesses":1,"finished":false,"solved":false},
                 "them":{"ready":true,"guesses":2,"finished":false,"solved":false}}
                """
                return (resp, Data(json.utf8))
            }
        }
        let repo = VersusRepository(client: client)
        let session = LiveDuelSession(challengeID: 1, puzzleID: "p", repository: repo)

        // Call #1 lands immediately when `start()` kicks the loop off; #2 and #3 follow at
        // `pollInterval` — the session's own real poll loop has to live through all three itself
        // for this to actually prove anything about its resilience.
        session.start()

        let reached0 = await waitUntil(timeout: 3) { session.opponentGuesses == 0 && session.state != nil }
        XCTAssertTrue(reached0, "the healthy first poll should have landed")
        XCTAssertFalse(session.pollFailing)

        let reached1 = await waitUntil(timeout: 3) { session.pollFailing }
        XCTAssertTrue(reached1, "the malformed poll should be flagged, not silently ignored")
        XCTAssertEqual(session.opponentGuesses, 0,
                       "a malformed poll must not clear the last good state")
        XCTAssertNotNil(session.state, "a malformed poll must not throw the whole duel away")

        let reached2 = await waitUntil(timeout: 3) { session.opponentGuesses == 2 }
        XCTAssertTrue(reached2, "the next good poll should recover")
        XCTAssertFalse(session.pollFailing)

        session.stop()
    }
}

/// Polls a condition on the main actor every 20ms up to `timeout` seconds — used instead of a
/// fixed `Task.sleep` wherever a test needs to observe `LiveDuelSession`'s own real poll loop
/// (on its real `pollInterval` cadence) rather than a value that updates synchronously.
@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// MARK: - Full two-client race simulation

/// A minimal in-memory stand-in for the `versus_challenges` row plus the four M23 §3 RPCs —
/// enough to drive two real `LiveDuelSession`s against `LiveMockURLProtocol` with no live
/// Postgres. This is **not** a test of the SQL itself (Stream A's job, verified against real
/// Postgres with real auth users) — it is a test of the client: does polling really converge on
/// one winner, does the loser's session really see that, does a bump really move the count the
/// opponent's strip reads. Also serves a `versus_series` row so the "the series counter
/// advances" half of the exit bar can be checked through the exact same `VersusSeries` decode
/// path the Versus tab already renders standings through — this fake's own win-increment logic
/// is a stand-in for `submit_versus_live_result`'s real one, not proof of it.
private final class FakeLiveDuelServer {
    let challengerID = "userA"
    let opponentID = "userB"
    private let lock = NSLock()
    private var challengerReady = false
    private var opponentReady = false
    private var liveStartedAt: Date?
    private var challengerGuesses = 0
    private var opponentGuesses = 0
    private var challengerFinished = false
    private var opponentFinished = false
    private var challengerSolved = false
    private var opponentSolved = false
    private var status = "pending"
    private var winnerID: String?
    private var winsA = 0
    private var winsB = 0
    private let timeLimitSeconds = 120
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    func handle(_ req: URLRequest) -> (HTTPURLResponse, Data) {
        let me = (req.value(forHTTPHeaderField: "Authorization") ?? "")
            .replacingOccurrences(of: "Bearer ", with: "")
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        lock.lock()
        defer { lock.unlock() }

        if let fn = req.rpcName {
            let body = req.jsonBody
            switch fn {
            case "mark_versus_ready":
                if me == challengerID { challengerReady = true } else { opponentReady = true }
                if challengerReady, opponentReady, liveStartedAt == nil { liveStartedAt = Date() }
            case "bump_versus_guesses":
                let n = body["p_guesses"] as? Int ?? 0
                if me == challengerID { challengerGuesses = n } else { opponentGuesses = n }
            case "submit_versus_live_result":
                let solved = body["p_solved"] as? Bool ?? false
                let n = body["p_guesses"] as? Int ?? 0
                if me == challengerID {
                    challengerGuesses = n; challengerFinished = true
                    if solved, status == "pending" {
                        challengerSolved = true; status = "completed"; winnerID = challengerID; winsA += 1
                    }
                } else {
                    opponentGuesses = n; opponentFinished = true
                    if solved, status == "pending" {
                        opponentSolved = true; status = "completed"; winnerID = opponentID; winsB += 1
                    }
                }
            case "versus_live_state":
                break   // just returns the current state below
            default:
                break
            }
            return (resp, stateJSON(for: me))
        }

        // The one table read this fake needs to serve: `versus_series`, for the win-counter check.
        if req.url?.path.contains("versus_series") == true {
            let json = """
            [{"id": 1, "user_a": "\(challengerID)", "user_b": "\(opponentID)", "sport": "nfl",
              "format": "journeyman", "wins_a": \(winsA), "wins_b": \(winsB), "status": "active"}]
            """
            return (resp, Data(json.utf8))
        }
        return (resp, Data("{}".utf8))
    }

    /// Not thread-safe on its own — always called with `lock` already held by `handle`.
    private func stateJSON(for me: String) -> Data {
        let iAmChallenger = me == challengerID
        let myGuesses = iAmChallenger ? challengerGuesses : opponentGuesses
        let myFinished = iAmChallenger ? challengerFinished : opponentFinished
        let mySolved = iAmChallenger ? challengerSolved : opponentSolved
        let theirGuesses = iAmChallenger ? opponentGuesses : challengerGuesses
        let theirFinished = iAmChallenger ? opponentFinished : challengerFinished
        let theirSolved = iAmChallenger ? opponentSolved : challengerSolved
        let startedString = liveStartedAt.map { "\"\(dateFormatter.string(from: $0))\"" } ?? "null"
        let winnerString = winnerID.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"mode": "live", "live_started_at": \(startedString),
         "server_now": "\(dateFormatter.string(from: Date()))",
         "time_limit_seconds": \(timeLimitSeconds), "status": "\(status)", "winner_id": \(winnerString),
         "me": {"ready": \(iAmChallenger ? challengerReady : opponentReady), "guesses": \(myGuesses),
                "finished": \(myFinished), "solved": \(mySolved)},
         "them": {"ready": \(iAmChallenger ? opponentReady : challengerReady), "guesses": \(theirGuesses),
                  "finished": \(theirFinished), "solved": \(theirSolved)}}
        """
        return Data(json.utf8)
    }
}

/// The exit bar's own scenario, spelled out: ready → both boards open → one solves → the other's
/// board sees a loss without ever solving itself → the series counter moves. Every assertion
/// reads off the client's real, shipped types (`LiveDuelSession`, `LiveRaceOutcome`, `VersusSeries`)
/// so a regression in any of them — not just in this test's fake server — would fail it.
@MainActor
final class LiveDuelRaceSimulationTests: XCTestCase {
    override func tearDown() { LiveMockURLProtocol.handler = nil; super.tearDown() }

    func testFullRaceOneSideSolvingClosesTheOthersBoardWithALossAndAdvancesTheSeries() async throws {
        let server = FakeLiveDuelServer()
        LiveMockURLProtocol.handler = { server.handle($0) }
        let (clientA, tokenA) = makeClient(user: server.challengerID)
        let (clientB, tokenB) = makeClient(user: server.opponentID)
        _ = (tokenA, tokenB)
        let repoA = VersusRepository(client: clientA)
        let repoB = VersusRepository(client: clientB)
        let sessionA = LiveDuelSession(challengeID: 1, puzzleID: "journeyman-nfl-test", repository: repoA)
        let sessionB = LiveDuelSession(challengeID: 1, puzzleID: "journeyman-nfl-test", repository: repoB)

        // Series starts even — sanity check before either side has played anything.
        let before: [VersusSeries] = try await clientA.select(
            "versus_series", query: [], decoder: .supabaseExplicitKeys)
        XCTAssertEqual(before.first?.winsA, 0)
        XCTAssertEqual(before.first?.winsB, 0)

        // Ready handshake — the board must not be considered open until both sides are in.
        try await sessionA.ready()
        XCTAssertFalse(sessionA.bothReady, "readying alone must not open the board")
        try await sessionB.ready()
        XCTAssertTrue(sessionB.state?.bothReady ?? false,
                      "the second READY should immediately see both sides in, without waiting a poll tick")

        // A's own poll loop should catch up to the same fact on its own next tick.
        let bothReady = await waitUntil(timeout: 3) { sessionA.bothReady }
        XCTAssertTrue(bothReady, "both sides readied, so the race should have started")

        // Interleaved guesses — each bump has to reach the *other* side's strip.
        await sessionA.reportGuesses(1)
        await sessionB.reportGuesses(1)
        await sessionA.reportGuesses(2)
        let reached3 = await waitUntil(timeout: 3) { sessionB.opponentGuesses == 2 }
        XCTAssertTrue(reached3, "B's strip should show A's latest guess count")
        let reached4 = await waitUntil(timeout: 3) { sessionA.opponentGuesses == 1 }
        XCTAssertTrue(reached4, "A's strip should show B's guess count")

        // A solves. `submitResult` polls once more itself, so A sees its own resolution
        // immediately — no waiting on the loop's own cadence.
        await sessionA.submitResult(solved: true, guesses: 3)
        XCTAssertTrue(sessionA.state?.me.solved ?? false)
        XCTAssertEqual(
            LiveRaceOutcome.decide(mySolved: sessionA.state?.me.solved ?? false,
                                   myFinished: sessionA.iAmFinished,
                                   theirSolved: sessionA.opponentSolved,
                                   theirFinished: sessionA.opponentFinished),
            .wonBySolvingFirst,
            "B never finished, so this must read as a live win, not a win-by-attrition")

        // B never solved and never submitted a result — its own next poll (on the loop `ready()`
        // already started) is the *only* thing that can tell it the duel is over. This is the
        // milestone's single most important behavior: B's board closes with a loss it never
        // chose, purely from what the poll reports.
        let reached5 = await waitUntil(timeout: 3) { sessionB.opponentAlreadyWon }
        XCTAssertTrue(reached5, "B's board must detect the opponent's win from the poll alone")
        XCTAssertEqual(
            LiveRaceOutcome.decide(mySolved: sessionB.state?.me.solved ?? false,
                                   myFinished: sessionB.iAmFinished,
                                   theirSolved: sessionB.opponentSolved,
                                   theirFinished: sessionB.opponentFinished),
            .lostToOpponentSolve)

        sessionA.stop()
        sessionB.stop()

        // The series counter actually moved for the winner, not just the local UI flags.
        let after: [VersusSeries] = try await clientA.select(
            "versus_series", query: [], decoder: .supabaseExplicitKeys)
        XCTAssertEqual(after.first?.winsA, 1, "the winner's series count should have advanced")
        XCTAssertEqual(after.first?.winsB, 0)
    }
}
