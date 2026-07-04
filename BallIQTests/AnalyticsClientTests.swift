import XCTest
@testable import BallIQ

/// Row-encoding for the first-party `events` pipeline (M15). Pure — the network side is
/// fire-and-forget `try?` by design, so the encodable shape is the testable contract.
final class AnalyticsClientTests: XCTestCase {

    func testSignedInRowShape() throws {
        let data = try AnalyticsClient.encodeRow(event: .gameCompleted,
                                                 properties: ["format": "keep4", "ranked": "true"],
                                                 userID: "user-1")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)   // PostgREST bulk-insert array shape
        XCTAssertEqual(rows[0]["event_name"] as? String, "game_completed")
        XCTAssertEqual(rows[0]["user_id"] as? String, "user-1")
        XCTAssertEqual(rows[0]["properties"] as? [String: String],
                       ["format": "keep4", "ranked": "true"])
    }

    func testSignedOutRowOmitsUserID() throws {
        // The RLS policy accepts a null user_id but rejects a mismatched one — signed-out
        // rows must omit the column entirely so the DB default (null) applies.
        let data = try AnalyticsClient.encodeRow(event: .gameStarted, properties: [:], userID: nil)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertNil(rows[0]["user_id"])
        XCTAssertEqual(rows[0]["properties"] as? [String: String], [:])
    }
}
