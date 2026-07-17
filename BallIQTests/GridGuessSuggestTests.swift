import XCTest
@testable import BallIQ

/// Locks the Grid guess autocomplete's ranking (GridGuessSheet.rank): prefix-before-interior,
/// diacritic/case folding, the ≥2-char floor, and the cap. The suggestion pool is sport-wide by
/// design, so these names stand in for the `grid_player_names` index — not any cell's answers.
final class GridGuessSuggestTests: XCTestCase {

    private static let names = [
        "Sam Darnold", "Darren Waller", "Stefon Diggs", "Saquon Barkley",
        "Patrick Mahomes", "Peyton Manning", "Eli Manning", "Nabil Bentaleb",
    ]

    func testPrefixMatchesRankAboveInterior() {
        // "man" is a prefix of nothing here but interior of the Mannings; "mah" prefixes Mahomes.
        let hits = GridGuessSheet.rank(query: "man", names: Self.names)
        XCTAssertEqual(Set(hits), ["Peyton Manning", "Eli Manning"])

        // "dar" prefixes Darnold and Darren Waller (first token), interior of nothing else.
        let dar = GridGuessSheet.rank(query: "dar", names: Self.names)
        XCTAssertEqual(dar.prefix(2).sorted(), ["Darren Waller", "Sam Darnold"])
    }

    func testFullNamePrefixWins() {
        // Normalization joins tokens with a space, so "sam d" is a prefix of "Sam Darnold".
        XCTAssertEqual(GridGuessSheet.rank(query: "sam d", names: Self.names), ["Sam Darnold"])
    }

    func testDiacriticAndCaseInsensitive() {
        XCTAssertEqual(GridGuessSheet.rank(query: "béntaleb", names: Self.names), ["Nabil Bentaleb"])
        XCTAssertEqual(GridGuessSheet.rank(query: "MAHOMES", names: Self.names), ["Patrick Mahomes"])
    }

    func testRequiresAtLeastTwoChars() {
        XCTAssertTrue(GridGuessSheet.rank(query: "d", names: Self.names).isEmpty)
        XCTAssertTrue(GridGuessSheet.rank(query: "", names: Self.names).isEmpty)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(GridGuessSheet.rank(query: "zzzz", names: Self.names).isEmpty)
    }

    func testResultsAreCappedAtLimit() {
        let many = (0..<50).map { "Player Number \($0)" }
        XCTAssertEqual(GridGuessSheet.rank(query: "player", names: many, limit: 8).count, 8)
    }

    func testEmptyIndexYieldsNoSuggestions() {
        XCTAssertTrue(GridGuessSheet.rank(query: "darnold", names: []).isEmpty)
    }

    // MARK: - No-reuse rule (one player per grid)

    func testDuplicateDetectionMatchesGraderLeniency() {
        let used = ["Tom Brady"]
        XCTAssertTrue(GridGuessSheet.isDuplicate("Tom Brady", usedNames: used))
        XCTAssertTrue(GridGuessSheet.isDuplicate("tom brady", usedNames: used))
        XCTAssertTrue(GridGuessSheet.isDuplicate("Tom Bradyy", usedNames: used), "single typo still a reuse")
        XCTAssertTrue(GridGuessSheet.isDuplicate("Brady", usedNames: used), "last name alone still a reuse")
        XCTAssertFalse(GridGuessSheet.isDuplicate("Peyton Manning", usedNames: used))
        XCTAssertFalse(GridGuessSheet.isDuplicate("Tom Brady", usedNames: []))
    }

    // MARK: - Emoji share grid

    func testShareTextEmojiLayout() {
        // Solved 0,1,4,8 → 🟩🟩⬛ / ⬛🟩⬛ / ⬛⬛🟩, row-major.
        let solved = [0: "A", 1: "B", 4: "C", 8: "D"]
        let date = ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!
        let text = GridResultView.shareText(sport: .nfl, score: 480, solved: solved, date: date)
        XCTAssertEqual(text, "Playbook Grid — NFL 2026-07-17\n🟩🟩⬛\n⬛🟩⬛\n⬛⬛🟩\nScore 480")
    }

    func testShareTextPerfectGrid() {
        let solved = Dictionary(uniqueKeysWithValues: (0..<9).map { ($0, "P\($0)") })
        let date = ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!
        let text = GridResultView.shareText(sport: .nba, score: 1500, solved: solved, date: date)
        XCTAssertTrue(text.contains("🟩🟩🟩\n🟩🟩🟩\n🟩🟩🟩"))
        XCTAssertFalse(text.contains("⬛"))
    }
}
