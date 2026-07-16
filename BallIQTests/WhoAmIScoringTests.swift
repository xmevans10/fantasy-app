import XCTest
@testable import BallIQ

final class WhoAmIScoringTests: XCTestCase {

    func testFirstClueSolveScoresMax() {
        let r = WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true)
        XCTAssertEqual(r.total, 1000)
        XCTAssertEqual(r.performance, 1.0, accuracy: 0.0001)
        XCTAssertTrue(r.solved)
    }

    func testLaterClueScoresLess() {
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 3, wrongGuesses: 0, solved: true).total, 600)
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 0, solved: true).total, 100)
    }

    func testWrongGuessesDeduct() {
        let r = WhoAmIScoring.score(cluesUsed: 2, wrongGuesses: 2, solved: true)
        XCTAssertEqual(r.total, 800 - 200) // 600
    }

    func testScoreFloorsAtZero() {
        let r = WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 5, solved: true)
        XCTAssertEqual(r.total, 0) // 100 - 500, clamped
    }

    func testUnsolvedScoresZeroPerformance() {
        let r = WhoAmIScoring.score(cluesUsed: 4, wrongGuesses: 1, solved: false)
        XCTAssertEqual(r.total, 0)
        XCTAssertEqual(r.performance, 0)
        XCTAssertFalse(r.solved)
    }

    // MARK: - Answer matching

    private let answer = WhoAmIPuzzle.AcceptedAnswer(
        canonical: "Allen Iverson", aliases: ["ai", "the answer"])

    func testExactAndCaseInsensitive() {
        XCTAssertTrue(AnswerMatcher.matches("Allen Iverson", answer: answer))
        XCTAssertTrue(AnswerMatcher.matches("allen iverson", answer: answer))
    }

    func testLastNameAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("Iverson", answer: answer))
    }

    func testAliasAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("The Answer", answer: answer))
    }

    func testSingleTypoAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("Iverson", answer:
            .init(canonical: "Iverson", aliases: [])))
        XCTAssertTrue(AnswerMatcher.matches("Iversen", answer:
            .init(canonical: "Iverson", aliases: [])))
    }

    func testWrongAnswerRejected() {
        XCTAssertFalse(AnswerMatcher.matches("Kobe Bryant", answer: answer))
        XCTAssertFalse(AnswerMatcher.matches("", answer: answer))
    }
}

/// `WhoAmIAnswerPhoto` — the reveal-time headshot resolution (WhoAmI content carries no
/// photo URL). The stakes are "whose face shows on the answer card," so these lock the
/// conservative rules: exact-name equality only, era-clue span excludes same-name players,
/// latest matching row wins.
final class WhoAmIAnswerPhotoTests: XCTestCase {
    private func puzzle(canonical: String, aliases: [String] = [], era: String?) -> WhoAmIPuzzle {
        var clues = [WhoAmIPuzzle.Clue(order: 2, kind: .fact, text: "Known for something")]
        if let era { clues.insert(.init(order: 1, kind: .era, text: era), at: 0) }
        return WhoAmIPuzzle(id: "t", sport: .nba, clues: clues,
                            answer: .init(canonical: canonical, aliases: aliases))
    }

    private func row(_ name: String, year: Int, headshot: String? = "https://img/x.png",
                     first: Int? = nil, last: Int? = nil) -> CatalogSeason {
        CatalogSeason(id: "\(name)-\(year)", sport: .nba, name: name, teamAbbr: "X",
                      seasonYear: year, position: "G", stats: [:],
                      headshot: headshot, firstYear: first, lastYear: last)
    }

    func testEraSpanParsesBothPipelineShapes() {
        XCTAssertEqual(WhoAmIAnswerPhoto.eraSpan(of: puzzle(canonical: "A", era: "Played from 1992 to 2011")), 1992...2011)
        XCTAssertEqual(WhoAmIAnswerPhoto.eraSpan(of: puzzle(canonical: "A", era: "Played in 1998")), 1998...1998)
        XCTAssertNil(WhoAmIAnswerPhoto.eraSpan(of: puzzle(canonical: "A", era: nil)))
    }

    func testExactNameMatchPicksLatestHeadshot() {
        let p = puzzle(canonical: "Shaquille O'Neal", era: "Played from 1992 to 2011")
        let rows = [row("Shaquille O'Neal", year: 1994), row("Shaquille O'Neal", year: 2009),
                    row("Kobe Bryant", year: 2009)]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: p), "https://img/x.png")
        // Latest row wins — prove it by giving the rows distinct URLs.
        let distinct = [row("Shaquille O'Neal", year: 1994, headshot: "https://img/old.png"),
                        row("Shaquille O'Neal", year: 2009, headshot: "https://img/new.png")]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: distinct, for: p), "https://img/new.png")
    }

    func testEraSpanExcludesSameNamePlayerFromAnotherEra() {
        // Jaren Jackson Sr. (1990s) must never supply Jr.'s (2018+) face, and vice versa.
        let junior = puzzle(canonical: "Jaren Jackson", era: "Played from 2018 to 2025")
        let rows = [row("Jaren Jackson", year: 1998, headshot: "https://img/sr.png"),
                    row("Jaren Jackson", year: 2023, headshot: "https://img/jr.png")]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: junior), "https://img/jr.png")
        let senior = puzzle(canonical: "Jaren Jackson", era: "Played from 1990 to 2002")
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: senior), "https://img/sr.png")
    }

    func testNoFuzzyMatchingAndNoEmptyHeadshots() {
        let p = puzzle(canonical: "Allen Iverson", era: nil)
        // Last-name-only and near-miss names are guess-grading leniency, not face-picking.
        let rows = [row("Iverson", year: 2001), row("Allan Iverson", year: 2001),
                    row("Allen Iverson", year: 2001, headshot: "")]
        XCTAssertNil(WhoAmIAnswerPhoto.headshot(from: rows, for: p))
    }

    func testCareerRowSpanUsesFirstAndLastYear() {
        let p = puzzle(canonical: "Tim Duncan", era: "Played from 1997 to 2016")
        // A career row keyed to its LAST season still overlaps via first/last span.
        let rows = [row("Tim Duncan", year: 2016, first: 1997, last: 2016)]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: p), "https://img/x.png")
    }
}
