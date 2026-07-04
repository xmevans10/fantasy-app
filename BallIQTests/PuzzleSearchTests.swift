import XCTest
@testable import BallIQ

/// Client-side text search (M13). Pure — same network-free pattern as
/// `CommunityFeedTests`/`BrowseFiltersTests`.
final class PuzzleSearchTests: XCTestCase {

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(PuzzleSearch.matches(query: "", in: ["anything"]))
        XCTAssertTrue(PuzzleSearch.matches(query: "   ", in: ["anything"]))
    }

    func testPartialTitleMatch() {
        let candidates = ["Elite WR receiving seasons"]
        XCTAssertTrue(PuzzleSearch.matches(query: "recei", in: candidates))
        XCTAssertTrue(PuzzleSearch.matches(query: "elite wr", in: candidates))
        XCTAssertFalse(PuzzleSearch.matches(query: "rushing", in: candidates))
    }

    func testPartialPlayerNameMatch() {
        XCTAssertTrue(PuzzleSearch.matches(query: "cee lam", in: ["CeeDee Lamb"]))
        XCTAssertTrue(PuzzleSearch.matches(query: "lamb", in: ["CeeDee Lamb"]))
        // Both tokens must land in the SAME candidate — no cross-string stitching.
        XCTAssertFalse(PuzzleSearch.matches(query: "cee henry", in: ["CeeDee Lamb", "Derrick Henry"]))
    }

    func testCaseAndDiacriticInsensitive() {
        XCTAssertTrue(PuzzleSearch.matches(query: "AMARE", in: ["Amar'e Stoudemire"]))
        XCTAssertTrue(PuzzleSearch.matches(query: "stoudemire", in: ["AMAR'E STOUDEMIRE"]))
        XCTAssertTrue(PuzzleSearch.matches(query: "donci", in: ["Luka Dončić"]))
    }

    func testMultiTokenNeedsEveryToken() {
        XCTAssertTrue(PuzzleSearch.matches(query: "derrick hen", in: ["Derrick Henry"]))
        XCTAssertFalse(PuzzleSearch.matches(query: "derrick lamb", in: ["Derrick Henry"]))
    }

    func testCommunitySearchesTitleAndDescriptionOnly() {
        let item = CommunitySummary(id: "x", authorId: "a", sport: .nfl, format: "whoami",
                                    title: "Guess my GOAT", playCount: 0,
                                    createdAt: "2026-07-01T00:00:00Z",
                                    description: "A 90s legend", scoring: nil, grain: nil, visibility: nil)
        XCTAssertTrue(PuzzleSearch.matches(query: "goat", community: item))
        XCTAssertTrue(PuzzleSearch.matches(query: "90s", community: item))
        XCTAssertFalse(PuzzleSearch.matches(query: "jordan", community: item))
    }
}
