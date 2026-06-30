import XCTest
@testable import BallIQ

final class BackendSyncTests: XCTestCase {

    func testParseSessionFromGoTrueResponse() throws {
        let json = #"""
        {"access_token":"AT","refresh_token":"RT","expires_in":3600,
         "token_type":"bearer","user":{"id":"uuid-123"}}
        """#
        let session = try AuthService.parseSession(from: Data(json.utf8))
        XCTAssertEqual(session.accessToken, "AT")
        XCTAssertEqual(session.refreshToken, "RT")
        XCTAssertEqual(session.userID, "uuid-123")
        XCTAssertGreaterThan(session.expiresAt, Date())          // ~1h out
        XCTAssertFalse(session.isExpired)
    }

    func testSessionExpiry() {
        let expired = Session(accessToken: "a", refreshToken: "r",
                              expiresAt: Date().addingTimeInterval(-10), userID: "u")
        XCTAssertTrue(expired.isExpired)
    }

    func testRatingMergeTakesMax() {
        XCTAssertEqual(RemoteSync.mergeRating(local: 1200, remote: 1100), 1200)
        XCTAssertEqual(RemoteSync.mergeRating(local: 1000, remote: 1300), 1300)
        XCTAssertEqual(RemoteSync.mergeRating(local: 1000, remote: nil), 1000) // no server row yet
    }

    func testNonceHashingIsStableAndHex() {
        let raw = "abc123"
        let a = AuthService.sha256(raw)
        let b = AuthService.sha256(raw)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)                               // SHA-256 hex
        XCTAssertNotEqual(AuthService.sha256("other"), a)
    }
}
