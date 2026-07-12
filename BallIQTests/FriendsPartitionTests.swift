import XCTest
@testable import BallIQ

/// `FriendsView.partition` (M19) — splits every edge the caller participates in into
/// incoming-pending / accepted / outgoing-pending buckets. Pure, so tested directly against
/// literal `FriendRow`s rather than through `SocialRepository`/network.
final class FriendsPartitionTests: XCTestCase {
    private let me = "me-uuid"

    private func row(_ other: String, status: String, requester: String, username: String? = nil) -> FriendRow {
        let edge = FriendEdge(requesterId: requester, addresseeId: requester == other ? me : other, status: status)
        return FriendRow(edge: edge, userID: other, username: username, avatar: nil)
    }

    func testMixedStatusesAndDirectionsPartitionCorrectly() {
        let incoming = row("them-incoming", status: "pending", requester: "them-incoming")   // they requested me
        let outgoing = row("them-outgoing", status: "pending", requester: me)                 // I requested them
        let accepted = row("them-accepted", status: "accepted", requester: me)

        let result = FriendsView.partition([incoming, outgoing, accepted], me: me)

        XCTAssertEqual(result.incoming.map(\.userID), ["them-incoming"])
        XCTAssertEqual(result.outgoing.map(\.userID), ["them-outgoing"])
        XCTAssertEqual(result.accepted.map(\.userID), ["them-accepted"])
    }

    func testEmptyInputProducesEmptyBuckets() {
        let result = FriendsView.partition([], me: me)
        XCTAssertTrue(result.incoming.isEmpty)
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertTrue(result.outgoing.isEmpty)
    }

    func testSelfEdgeNeverAppearsInAnyBucket() {
        // Should never happen server-side (the DB rejects requester == addressee, and
        // SocialRepository never constructs one), but the partition must still defend
        // against rendering a "friend" row for yourself if one ever slipped through.
        let selfEdge = FriendEdge(requesterId: me, addresseeId: me, status: "accepted")
        let selfRow = FriendRow(edge: selfEdge, userID: me, username: "me", avatar: nil)
        let normal = row("them", status: "accepted", requester: me)

        let result = FriendsView.partition([selfRow, normal], me: me)

        XCTAssertEqual(result.accepted.map(\.userID), ["them"])
        XCTAssertFalse(result.incoming.contains { $0.userID == me })
        XCTAssertFalse(result.accepted.contains { $0.userID == me })
        XCTAssertFalse(result.outgoing.contains { $0.userID == me })
    }

    func testAllThreeBucketsCanCoexistWithMultipleRowsEach() {
        let rows = [
            row("a", status: "pending", requester: "a"),
            row("b", status: "pending", requester: "b"),
            row("c", status: "pending", requester: me),
            row("d", status: "pending", requester: me),
            row("e", status: "accepted", requester: me),
            row("f", status: "accepted", requester: "f"),
        ]
        let result = FriendsView.partition(rows, me: me)
        XCTAssertEqual(Set(result.incoming.map(\.userID)), ["a", "b"])
        XCTAssertEqual(Set(result.outgoing.map(\.userID)), ["c", "d"])
        XCTAssertEqual(Set(result.accepted.map(\.userID)), ["e", "f"])
    }
}
