import XCTest
@testable import BallIQ

/// The viral loop's contract.
///
/// Two things are locked here and both are load-bearing:
///  1. **The link round-trips.** A challenge that decodes to a different board than it encoded
///     would silently compare two scores set on two different puzzles — a wrong head-to-head is
///     worse than none, because it looks authoritative.
///  2. **The exact share text.** This string is the entire distribution mechanism; it is also the
///     thing most likely to be "tidied" by someone who doesn't know the shape is deliberate.
final class ChallengeLinkTests: XCTestCase {

    /// 2026-07-27 12:00 UTC — matches the day string used throughout, so "today's" resolves.
    private let now = ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")!
    private let day = "2026-07-27"

    private func grid(hits: Int = 7, score: Int = 1240,
                      challenger: String? = "Alex") -> ChallengeLink {
        ChallengeLink(format: .grid, sport: .nfl, day: day, hits: hits, outOf: 9,
                      score: score, challenger: challenger)
    }

    // MARK: - Round trip

    func testURLRoundTripsEveryField() throws {
        let original = grid()
        let parsed = try XCTUnwrap(ChallengeLink.parse(original.url))
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripSurvivesASpacedUsername() throws {
        // Display names are free text; a space must percent-encode and come back intact rather
        // than truncating the name or breaking the query.
        let original = ChallengeLink(format: .keep4, sport: .soccer, day: day, hits: 6, outOf: 8,
                                     score: 1500, challenger: "Sam O'Neill Jr")
        let parsed = try XCTUnwrap(ChallengeLink.parse(original.url))
        XCTAssertEqual(parsed.challenger, "Sam O'Neill Jr")
        XCTAssertEqual(parsed, original)
    }

    func testAnonymousChallengeOmitsTheNameEntirely() throws {
        let parsed = try XCTUnwrap(ChallengeLink.parse(grid(challenger: nil).url))
        XCTAssertNil(parsed.challenger)
        XCTAssertFalse(grid(challenger: nil).url.absoluteString.contains("n="))
    }

    /// A signed-out player has `identity.username == nil`, but an empty string is just as
    /// reachable (a profile saved and cleared). Both must mean "no name", not a name of "".
    func testBlankUsernameNormalisesToNil() {
        XCTAssertNil(grid(challenger: "   ").challenger)
        XCTAssertNil(grid(challenger: "").challenger)
    }

    // MARK: - Parsing rejects

    func testParseRejectsThePlayDeepLink() {
        // `balliq://play/<id>` is the other, pre-existing deep link. If `parse` claimed it,
        // ContentView would route every shared community puzzle into the challenge flow.
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://play/abc123")!))
    }

    func testParseRejectsForeignSchemesAndHosts() {
        XCTAssertNil(ChallengeLink.parse(URL(string: "https://challenge?f=grid&s=nfl&d=2026-07-27&h=7&o=9&p=1&n=A")!))
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://elsewhere?f=grid&s=nfl&d=2026-07-27&h=7&o=9&p=1")!))
    }

    func testParseRejectsMissingOrJunkNumbers() {
        // A defaulted 0 here would tell the recipient they'd already won before playing.
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=grid&s=nfl&d=2026-07-27&o=9&p=100")!))
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=grid&s=nfl&d=2026-07-27&h=x&o=9&p=100")!))
    }

    func testParseRejectsImpossibleScores() {
        // 12/9 is not a Grid result; accepting it makes every recipient a guaranteed loser.
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=grid&s=nfl&d=2026-07-27&h=12&o=9&p=100")!))
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=grid&s=nfl&d=2026-07-27&h=-1&o=9&p=100")!))
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=grid&s=nfl&d=2026-07-27&h=0&o=0&p=100")!))
    }

    func testParseRejectsUnknownFormatsAndSports() {
        // Over/Under has no shared board (see `ChallengeLink.Format`) — a link claiming one is
        // either a bug or hand-crafted, and either way must not resolve.
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=overunder&s=nfl&d=2026-07-27&h=7&o=9&p=1")!))
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=grid&s=cricket&d=2026-07-27&h=7&o=9&p=1")!))
    }

    /// The day goes into a PostgREST `active_date` filter, so its shape is checked at the
    /// boundary rather than trusted because it arrived in a URL.
    func testDayStringValidation() {
        XCTAssertTrue(ChallengeLink.isDayString("2026-07-27"))
        XCTAssertFalse(ChallengeLink.isDayString("2026-7-27"))
        XCTAssertFalse(ChallengeLink.isDayString("2026-13-01"))
        XCTAssertFalse(ChallengeLink.isDayString("2026-07-32"))
        XCTAssertFalse(ChallengeLink.isDayString("yesterday"))
        XCTAssertFalse(ChallengeLink.isDayString("2026-07-27' or 1=1--"))
        XCTAssertNil(ChallengeLink.parse(URL(string: "balliq://challenge?f=grid&s=nfl&d=notaday&h=7&o=9&p=1")!))
    }

    /// The date is what actually resolves the board (`gridPuzzle(for:date:)` reformats it as a
    /// local day), so it has to survive the round trip through `Date` unchanged — the noon-local
    /// anchor in `ChallengeLink.date` is what guarantees this in every timezone.
    func testDateResolvesBackToTheSameLocalDay() throws {
        let date = try XCTUnwrap(grid().date)
        XCTAssertEqual(PuzzleStore.localDayString(date), day)
    }

    // MARK: - Head to head

    func testMoreHitsAlwaysWinsRegardlessOfPoints() {
        // 7/9 beats 6/9 even when the 6/9 racked up more points.
        XCTAssertEqual(grid(hits: 7, score: 100).outcome(hits: 6, score: 99_999), .loss)
        XCTAssertEqual(grid(hits: 7, score: 100).outcome(hits: 8, score: 1), .win)
    }

    func testPointsOnlyBreakATieOnHits() {
        XCTAssertEqual(grid(hits: 7, score: 1240).outcome(hits: 7, score: 1300), .win)
        XCTAssertEqual(grid(hits: 7, score: 1240).outcome(hits: 7, score: 1000), .loss)
        XCTAssertEqual(grid(hits: 7, score: 1240).outcome(hits: 7, score: 1240), .tie)
    }

    // MARK: - The message

    func testGridShareTextIsExactlyThis() {
        let solved = [0: "A", 1: "B", 4: "C", 8: "D"]
        let text = GridResultView.shareText(sport: .nfl, score: 480, solved: solved,
                                            date: now, challenger: "Alex", now: now)
        XCTAssertEqual(text, """
        I went 4/9 on today's NFL Grid — beat that.
        🟩🟩⬛
        ⬛🟩⬛
        ⬛⬛🟩
        4/9 · 480 pts
        https://apps.apple.com/app/id6785275045?ct=chal_grid_nfl
        """)
    }

    /// The picture must never be the last line: chat clients truncate long messages and the link
    /// is the only part that does any work.
    func testTheLinkIsAlwaysTheLastLine() {
        let text = GridResultView.shareText(sport: .nba, score: 900, solved: [0: "A"],
                                            date: now, now: now)
        XCTAssertTrue(text.hasSuffix("https://apps.apple.com/app/id6785275045?ct=chal_grid_nba"))
    }

    func testPerfectGridHasNoMissMarks() {
        let solved = Dictionary(uniqueKeysWithValues: (0..<9).map { ($0, "P\($0)") })
        let text = GridResultView.shareText(sport: .nba, score: 1500, solved: solved,
                                            date: now, now: now)
        XCTAssertTrue(text.contains("🟩🟩🟩\n🟩🟩🟩\n🟩🟩🟩"))
        XCTAssertFalse(text.contains("⬛"))
        XCTAssertTrue(text.hasPrefix("I went 9/9 on today's NBA Grid"))
    }

    /// A re-rolled practice board isn't pinned to `(sport, day)`, so it must not carry a dare the
    /// recipient can't actually take up on the same board.
    func testPracticeBoardShareMakesNoChallenge() {
        let text = GridResultView.shareText(sport: .nfl, score: 300, solved: [0: "A"],
                                            date: now, isDaily: false, now: now)
        XCTAssertTrue(text.hasPrefix("I went 1/9 on a NFL Grid."))
        XCTAssertFalse(text.contains("beat that"))
        XCTAssertTrue(text.contains("apps.apple.com"))
    }

    /// A challenge opened the next day still has to read correctly.
    func testDatedBoardDropsTheWordToday() {
        let tomorrow = now.addingTimeInterval(24 * 3600)
        XCTAssertTrue(grid().headline(now: tomorrow).contains("the Jul 27 NFL Grid"))
        XCTAssertTrue(grid().headline(now: now).contains("today's NFL Grid"))
    }

    func testScoreLineGroupsThousands() {
        XCTAssertEqual(grid(hits: 7, score: 1240).scoreLine, "7/9 · 1,240 pts")
    }

    // MARK: - Keep 4

    private func keep4Puzzle() -> Keep4Puzzle {
        let players = (0..<8).map { i in
            PlayerSeason(id: "p\(i)", name: "P\(i)", teamAbbr: "TM",
                         seasonYear: 2000 + i, stats: [], grade: Double(80 - i * 10))
        }
        return Keep4Puzzle(id: "t", theme: "Test", sport: .nfl, players: players)
    }

    func testKeep4ShareTextIsExactlyThis() {
        let puzzle = keep4Puzzle()
        var placement: [String: Pile] = [:]
        for i in 0..<4 { placement["p\(i)"] = .keep }
        for i in 4..<8 { placement["p\(i)"] = .cut }
        placement["p0"] = .cut          // one wrong keep …
        placement["p4"] = .keep         // … and its matching wrong cut
        let result = Keep4Scoring.score(puzzle: puzzle, placement: placement)

        let text = Keep4ResultView.shareText(puzzle: puzzle, result: result,
                                             date: now, challenger: "Alex", now: now)
        XCTAssertEqual(text, """
        I went 6/8 on today's NFL Keep 4 — beat that.
        ⬛🟩🟩🟩
        ⬛🟩🟩🟩
        6/8 · 1,500 pts
        https://apps.apple.com/app/id6785275045?ct=chal_keep4_nfl
        """)
    }

    /// The same result view serves the archive, community puzzles, Versus and deep links. A 2019
    /// archive run must not go out as "today's NFL Keep 4 — beat that", which would dare the
    /// recipient onto a board they'll never be served.
    func testArchiveAndCommunityRunsMakeNoChallenge() {
        let puzzle = keep4Puzzle()
        let placement = Dictionary(uniqueKeysWithValues: puzzle.players.map { ($0.id, Pile.keep) })
        let result = Keep4Scoring.score(puzzle: puzzle, placement: placement)
        let text = Keep4ResultView.shareText(puzzle: puzzle, result: result, date: now,
                                             isDaily: false, now: now)
        XCTAssertTrue(text.hasPrefix("I went 4/8 on a NFL Keep 4."))
        XCTAssertFalse(text.contains("today's"))
        XCTAssertFalse(text.contains("beat that"))
        XCTAssertTrue(text.contains("apps.apple.com"))
    }

    /// `ShareCardView` renders every player with KEEP/CUT and a tick — the complete answer key.
    /// Whatever else the Keep 4 share does, it must not name a player.
    func testKeep4ShareLeaksNoPlayerNames() {
        let puzzle = keep4Puzzle()
        let placement = Dictionary(uniqueKeysWithValues: puzzle.players.map { ($0.id, Pile.keep) })
        let result = Keep4Scoring.score(puzzle: puzzle, placement: placement)
        let text = Keep4ResultView.shareText(puzzle: puzzle, result: result, date: now, now: now)
        for player in puzzle.players {
            XCTAssertFalse(text.contains(player.name), "share text leaked \(player.name)")
        }
    }

    // MARK: - Who Am I? (no shared board — a brag, not a challenge)

    private func whoAmIPuzzle() -> WhoAmIPuzzle {
        WhoAmIPuzzle(id: "w", sport: .nba,
                     clues: (1...6).map { .init(order: $0, kind: .fact, text: "clue \($0)") },
                     answer: .init(canonical: "Allen Iverson", aliases: []))
    }

    func testWhoAmICluesRenderAsSpendNotCorrectness() {
        let puzzle = whoAmIPuzzle()
        let solved = WhoAmIScoring.score(cluesUsed: 3, wrongGuesses: 0, solved: true)
        XCTAssertEqual(WhoAmIResultView.emojiClues(result: solved, clueCount: 6), "⬛⬛🟩⬜⬜⬜")

        let failed = WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 0, solved: false)
        XCTAssertEqual(WhoAmIResultView.emojiClues(result: failed, clueCount: 6), "⬛⬛⬛⬛⬛⬛")
    }

    func testWhoAmIShareNeverNamesTheAnswer() {
        let puzzle = whoAmIPuzzle()
        let result = WhoAmIScoring.score(cluesUsed: 2, wrongGuesses: 0, solved: true)
        let text = WhoAmIResultView.shareText(puzzle: puzzle, result: result)
        XCTAssertFalse(text.contains("Allen Iverson"))
        XCTAssertFalse(text.lowercased().contains("iverson"))
        XCTAssertTrue(text.hasPrefix("I got today's NBA Who Am I? in 2 clues."))
        XCTAssertTrue(text.hasSuffix("?ct=res_whoami_nba"))
    }

    func testOverUnderShareReadsAsAStreakBrag() {
        let text = OverUnderResultView.shareText(sport: .baseball, score: 2300,
                                                 correctCount: 14, beatHighScore: true)
        XCTAssertTrue(text.hasPrefix("New personal best on MLB Over/Under: 14 straight."))
        XCTAssertTrue(text.hasSuffix("?ct=res_overunder_baseball"))
    }

    /// Every surface's score goes through one formatter. Caught by looking at the rendered
    /// gallery: the Grid said "1,240 pts" and Over/Under said "2300 pts" in the same set.
    func testEverySharedScoreGroupsThousandsTheSameWay() {
        XCTAssertEqual(ShareMessage.points(2300), "2,300")
        XCTAssertTrue(OverUnderResultView.shareText(sport: .nba, score: 2300, correctCount: 14,
                                                    beatHighScore: false).contains("2,300 pts"))
        XCTAssertTrue(grid(hits: 7, score: 1240).scoreLine.contains("1,240 pts"))
        let whoAmI = WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true)
        XCTAssertTrue(WhoAmIResultView.shareText(puzzle: whoAmIPuzzle(), result: whoAmI)
                        .contains("1,000 pts"))
    }

    // MARK: - The shared template

    func testComposeKeepsHeadlineBoardDetailLinkInThatOrder() {
        let text = ShareMessage.compose(headline: "H", board: "B", detail: "D", campaign: "c")
        XCTAssertEqual(text, "H\nB\nD\nhttps://apps.apple.com/app/id6785275045?ct=c")
    }

    func testComposeOmitsAnEmptyBoardWithoutLeavingABlankLine() {
        XCTAssertEqual(ShareMessage.compose(headline: "H", board: "", detail: "D", campaign: "c"),
                       "H\nD\nhttps://apps.apple.com/app/id6785275045?ct=c")
        XCTAssertEqual(ShareMessage.compose(headline: "H", detail: "D", campaign: "c"),
                       "H\nD\nhttps://apps.apple.com/app/id6785275045?ct=c")
    }

    func testEmojiRowWraps() {
        XCTAssertEqual(ShareMessage.emojiRow([true, false, true, true], perLine: 2), "🟩⬛\n🟩🟩")
        XCTAssertEqual(ShareMessage.emojiRow([true, false, true], perLine: 9), "🟩⬛🟩")
    }

    // MARK: - Puzzle invites

    /// The old share sent a bare `balliq://play/<id>` under copy promising "anyone can play" —
    /// which opened nothing for anyone without the app. Every invite must now carry a URL a
    /// stranger's phone will actually resolve.
    func testPuzzleInviteCarriesAnInstallableLink() {
        let puzzle = SharablePuzzle(whoAmI: whoAmIPuzzle())
        let text = puzzle.shareText
        XCTAssertTrue(text.hasPrefix("My Playbook puzzle: A mystery player. 6 clues — guess who"))
        XCTAssertTrue(text.contains("https://apps.apple.com/app/id6785275045?ct=puzzle_invite"))
        XCTAssertTrue(text.contains("balliq://play/w"), "installed users still get the deep link")
        XCTAssertFalse(text.contains("Allen Iverson"), "a shared Who Am I? must not leak its answer")
    }

    func testPuzzleInviteReportsAMachineFormat() {
        XCTAssertEqual(SharablePuzzle(whoAmI: whoAmIPuzzle()).analyticsFormat, "whoami")
        XCTAssertEqual(SharablePuzzle(keep4: keep4Puzzle()).analyticsFormat, "keep4")
    }

    // MARK: - Analytics vocabulary

    /// Same rule as the purchase funnel's: these strings are column values, history can't be
    /// renamed retroactively, so a rename breaks a test instead of splitting a funnel.
    func testLoopEventNamesAreStable() {
        XCTAssertEqual(AnalyticsEvent.shareTapped.rawValue, "share_tapped")
        XCTAssertEqual(AnalyticsEvent.shareLinkOpened.rawValue, "share_link_opened")
        XCTAssertEqual(AnalyticsEvent.challengeStarted.rawValue, "challenge_started")
        XCTAssertEqual(AnalyticsEvent.challengeCompleted.rawValue, "challenge_completed")
    }

    func testShareArtifactRawValuesAreStable() {
        XCTAssertEqual(ShareArtifact.challengeText.rawValue, "challenge_text")
        XCTAssertEqual(ShareArtifact.resultImage.rawValue, "result_image")
        XCTAssertEqual(ShareArtifact.puzzleLink.rawValue, "puzzle_link")
        XCTAssertEqual(ShareArtifact.profileImage.rawValue, "profile_image")
    }

    /// Every share site reports all three dimensions — the reason the existing 6 `share_tapped`
    /// rows can't answer anything is that they carry `surface` alone.
    func testSharePropertiesAlwaysCarryAllThreeDimensions() {
        let props = AnalyticsEvent.shareProperties(surface: "grid_result", format: "grid",
                                                   artifact: .challengeText,
                                                   extra: ["sport": "nfl"])
        XCTAssertEqual(props["surface"], "grid_result")
        XCTAssertEqual(props["format"], "grid")
        XCTAssertEqual(props["artifact"], "challenge_text")
        XCTAssertEqual(props["sport"], "nfl")
    }

    func testShareRowSurvivesTheEncoder() throws {
        let data = try AnalyticsClient.encodeRow(
            event: .shareTapped,
            properties: AnalyticsEvent.shareProperties(surface: "grid_result", format: "grid",
                                                       artifact: .challengeText),
            userID: "user-1")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows[0]["event_name"] as? String, "share_tapped")
        XCTAssertEqual(rows[0]["properties"] as? [String: String],
                       ["surface": "grid_result", "format": "grid", "artifact": "challenge_text"])
    }
}
