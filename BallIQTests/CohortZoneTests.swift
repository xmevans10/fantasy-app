import XCTest
@testable import BallIQ

/// Zone math for the Leagues standings — the same `min(5, n/2)` cutoffs the server rollover
/// applies, verified at the sizes that actually matter: a solo cohort (no movement is
/// possible), the smallest cohort where a zone forms, the exact boundary of `n/2` rounding
/// (9 vs 10), and a full 30-player cohort.
final class CohortZoneTests: XCTestCase {

    func testSingleMemberCohortHasNoZones() {
        let cutoffs = LeagueRules.cutoffs(memberCount: 1)
        XCTAssertEqual(cutoffs.promote, 0)
        XCTAssertEqual(cutoffs.relegate, 0)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 0, memberCount: 1), .hold)
    }

    func testTwoMemberCohortHasNoZones() {
        // n/2 = 1 but that would mean both players promote AND relegate — the server's own
        // math still applies `min(5, n/2)` = 1 per zone here, so keep the client mirroring it
        // exactly rather than special-casing it away.
        let cutoffs = LeagueRules.cutoffs(memberCount: 2)
        XCTAssertEqual(cutoffs.promote, 1)
        XCTAssertEqual(cutoffs.relegate, 1)
    }

    func testNineMemberCohortRoundsDownToFour() {
        let cutoffs = LeagueRules.cutoffs(memberCount: 9)
        XCTAssertEqual(cutoffs.promote, 4)
        XCTAssertEqual(cutoffs.relegate, 4)
        // With 4 promoting and 4 relegating, only the exact middle (index 4) holds —
        // index 5 is already in the relegation zone (i >= n - cutoff = 5), same as the server.
        XCTAssertEqual(LeagueRules.zone(rankIndex: 3, memberCount: 9), .promote)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 4, memberCount: 9), .hold)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 5, memberCount: 9), .relegate)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 8, memberCount: 9), .relegate)
    }

    func testTenMemberCohortCutsAtFive() {
        let cutoffs = LeagueRules.cutoffs(memberCount: 10)
        XCTAssertEqual(cutoffs.promote, 5)
        XCTAssertEqual(cutoffs.relegate, 5)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 4, memberCount: 10), .promote)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 5, memberCount: 10), .relegate)
    }

    func testElevenMemberCohortHoldsTheMiddleRow() {
        let cutoffs = LeagueRules.cutoffs(memberCount: 11)
        XCTAssertEqual(cutoffs.promote, 5)
        XCTAssertEqual(cutoffs.relegate, 5)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 4, memberCount: 11), .promote)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 5, memberCount: 11), .hold)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 6, memberCount: 11), .relegate)
    }

    func testThirtyMemberCohortCapsAtFiveEachSide() {
        let cutoffs = LeagueRules.cutoffs(memberCount: 30)
        XCTAssertEqual(cutoffs.promote, 5)
        XCTAssertEqual(cutoffs.relegate, 5)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 0, memberCount: 30), .promote)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 4, memberCount: 30), .promote)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 5, memberCount: 30), .hold)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 24, memberCount: 30), .hold)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 25, memberCount: 30), .relegate)
        XCTAssertEqual(LeagueRules.zone(rankIndex: 29, memberCount: 30), .relegate)
    }
}
