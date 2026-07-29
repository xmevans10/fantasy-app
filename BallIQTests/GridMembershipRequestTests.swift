import XCTest
@testable import BallIQ

/// Pins what the membership fetch actually puts on the wire.
///
/// This exists because of a bug that every other test missed. `GridLocalGeneratorTests` builds
/// its indexes in memory, already carrying axes, so the generator looked correct — and it was.
/// The defect was one field further out: `MembershipArgs` sent only `p_sport`, and the RPC
/// defaults `p_version` to **1**. A v1 payload has no `axes`, so
/// `GridLocalGenerator.feasibleArchetypes` bailed at `guard index.hasAxes` and was left with
/// teams-x-decades and teams-x-teams. On device every practice board came back teams-on-both-
/// axes — precisely the sameness the whole v2 axis project existed to remove — while the unit
/// tests stayed green and the server happily served v2 to anyone who asked for it.
///
/// The lesson worth locking in: when a request's shape decides which features exist, assert the
/// request, not just the code that consumes its response.
@MainActor
final class GridMembershipRequestTests: XCTestCase {

    private let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "ANON123")

    private func makeClient() -> SupabaseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(config: config, session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridMembershipRequestTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DiskCache.directoryOverride = dir
    }

    override func tearDown() {
        if let dir = DiskCache.directoryOverride { try? FileManager.default.removeItem(at: dir) }
        DiskCache.directoryOverride = nil
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// The regression this file exists for: the request must explicitly ask for the current
    /// version. Relying on the RPC's default silently downgrades the client to an axis-less
    /// payload.
    func testRequestsTheCurrentPayloadVersionExplicitly() async {
        var body: String?
        var path: String?
        MockURLProtocol.handler = { req in
            path = req.url?.path
            if let data = req.httpBody ?? req.httpBodyStream.map(Self.drain) {
                body = String(data: data, encoding: .utf8)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("null".utf8))
        }

        let repo = RemotePuzzleRepository(client: makeClient())
        _ = await repo.gridMembershipIndex(for: .nfl)

        XCTAssertEqual(path, "/rest/v1/rpc/grid_membership_index")
        let sent = body ?? ""
        XCTAssertTrue(sent.contains("\"p_sport\""), "sport must be sent, got: \(sent)")
        XCTAssertTrue(sent.contains("\"p_version\":\(GridMembershipIndex.currentVersion)")
                      || sent.contains("\"p_version\" : \(GridMembershipIndex.currentVersion)"),
                      "must request v\(GridMembershipIndex.currentVersion) explicitly — the RPC "
                      + "defaults to 1, which carries no axes. Got: \(sent)")
    }

    /// `currentVersion` is the number the RPC is asked for, so it has to be a version the client
    /// can actually decode. If these drift the app requests a payload it will then reject.
    func testCurrentVersionIsOneThisBuildSupports() {
        XCTAssertTrue(GridMembershipIndex.supportedVersions.contains(GridMembershipIndex.currentVersion))
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(contentsOf: buf[0..<read])
        }
        return data
    }
}
