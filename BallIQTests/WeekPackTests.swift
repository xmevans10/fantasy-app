import XCTest
@testable import BallIQ

/// Week Packs on the client: lossy item decoding, which pack is current, progress, titles.
final class WeekPackTests: XCTestCase {

    private func playersJSON(_ prefix: String) -> String {
        (0..<8).map { i in
            #"{"id":"\#(prefix)\#(i)","name":"P\#(i)","teamAbbr":"KC","seasonYear":2026,"stats":[],"grade":\#(40 - i)}"#
        }.joined(separator: ",")
    }

    private func itemJSON(id: String, pack: String, ordinal: Int, role: String = "game",
                          format: String = "keep4", theme: String = "2026 Week 1: top TE performances") -> String {
        #"{"id":"\#(id)","pack_id":"\#(pack)","ordinal":\#(ordinal),"role":"\#(role)","format":"\#(format)","content":{"id":"\#(id)","theme":"\#(theme)","sport":"nfl","players":[\#(playersJSON(id))]}}"#
    }

    private func decodeItems(_ rows: [String]) throws -> [WeekPackItemRow] {
        let data = Data("[\(rows.joined(separator: ","))]".utf8)
        return try JSONDecoder().decode([Lossy<WeekPackItemRow>].self, from: data).compactMap(\.value)
    }

    private func pack(_ id: String, sport: Sport = .nfl, release: String, items: Int = 5) -> WeekPack {
        let rows = (0..<items).map { i in
            WeekPackItem(id: "\(id)-\(i)", ordinal: i, role: i == 0 ? .headline : .niche,
                         board: .keep4(Keep4Puzzle(id: "\(id)-\(i)", theme: "T", sport: sport,
                                                   players: [])))
        }
        return WeekPack(id: id, sport: sport, label: "2026 Week 1", releaseDate: release, items: rows)
    }

    // MARK: Decoding

    func testAnUnknownFormatItemIsSkippedNotFatal() throws {
        let rows = try decodeItems([
            itemJSON(id: "a", pack: "nfl-2026-wk01", ordinal: 0, role: "headline"),
            itemJSON(id: "b", pack: "nfl-2026-wk01", ordinal: 1, format: "overunder_week"),
            itemJSON(id: "c", pack: "nfl-2026-wk01", ordinal: 2),
        ])
        let items = rows.compactMap(\.item)
        XCTAssertEqual(items.map(\.id), ["a", "c"])
        XCTAssertEqual(items.first?.role, .headline)
    }

    func testAMalformedRowIsSkippedNotFatal() throws {
        let rows = try decodeItems([
            #"{"id":"broken"}"#,
            itemJSON(id: "ok", pack: "nfl-2026-wk01", ordinal: 1),
        ])
        XCTAssertEqual(rows.compactMap(\.item).map(\.id), ["ok"])
    }

    func testAnUnknownRoleDecodesAsOther() throws {
        let rows = try decodeItems([itemJSON(id: "a", pack: "p", ordinal: 0, role: "rivalry")])
        XCTAssertEqual(rows.first?.item?.role, .other)
    }

    func testAssembleOrdersItemsAndGroupsByPack() throws {
        let rows = try decodeItems([
            itemJSON(id: "c", pack: "p1", ordinal: 2),
            itemJSON(id: "a", pack: "p1", ordinal: 0),
            itemJSON(id: "x", pack: "p2", ordinal: 0),
        ])
        let packs = WeekPackSchedule.assemble(
            packs: [WeekPackRow(id: "p1", sport: .nfl, label: "2026 Week 1", releaseDate: "2026-09-16"),
                    WeekPackRow(id: "p2", sport: .nba, label: "Sep 7 to 13", releaseDate: "2026-09-17")],
            items: rows)
        XCTAssertEqual(packs[0].items.map(\.id), ["a", "c"])
        XCTAssertEqual(packs[1].items.map(\.id), ["x"])
    }

    // MARK: Which pack is current

    func testAPackIsHiddenBeforeItsReleaseDay() {
        XCTAssertTrue(WeekPackSchedule.current([pack("p", release: "2026-09-16")], today: "2026-09-15").isEmpty)
        XCTAssertEqual(WeekPackSchedule.current([pack("p", release: "2026-09-16")], today: "2026-09-16").count, 1)
    }

    func testAPackStaysCurrentForExactlySevenDays() {
        let p = pack("p", release: "2026-09-16")
        XCTAssertTrue(WeekPackSchedule.isCurrent(p, today: "2026-09-22"))
        XCTAssertFalse(WeekPackSchedule.isCurrent(p, today: "2026-09-23"))
    }

    func testTheNewestPackPerSportWins() {
        let current = WeekPackSchedule.current([pack("wk1", release: "2026-09-16"),
                                                pack("wk2", release: "2026-09-23"),
                                                pack("nba", sport: .nba, release: "2026-09-17")],
                                               today: "2026-09-23")
        XCTAssertEqual(current.map(\.id), ["wk2", "nba"])
    }

    func testAPackWithNoReadableBoardsNeverShows() {
        XCTAssertTrue(WeekPackSchedule.current([pack("p", release: "2026-09-16", items: 0)],
                                               today: "2026-09-16").isEmpty)
    }

    func testTheWindowCrossesMonthAndYearBoundaries() {
        XCTAssertEqual(WeekPackSchedule.windowStart(today: "2026-10-03"), "2026-09-26")
        XCTAssertEqual(WeekPackSchedule.windowStart(today: "2027-01-02"), "2026-12-26")
    }

    // MARK: Daily, progress, titles

    func testBoardZeroIsTheDailyOnlyOnReleaseDay() {
        let p = pack("p", release: "2026-09-16")
        XCTAssertTrue(p.isDaily(p.items[0], today: "2026-09-16"))
        XCTAssertFalse(p.isDaily(p.items[0], today: "2026-09-17"))
        XCTAssertFalse(p.isDaily(p.items[1], today: "2026-09-16"))
    }

    func testProgressReadsTheCareerLogByBoardID() {
        let p = pack("p", release: "2026-09-16", items: 3)
        let results = [result(puzzleID: "p-0", correct: 6), result(puzzleID: "p-2", correct: 8),
                       result(puzzleID: "somewhere-else", correct: 8)]
        let progress = WeekPackProgress(pack: p, results: results)
        XCTAssertEqual(progress.playedCount(in: p), 2)
        XCTAssertFalse(progress.isComplete(p))
        XCTAssertEqual(progress.totalCorrect(in: p), 14)
        let done = WeekPackProgress(pack: p, results: results + [result(puzzleID: "p-1", correct: 3)])
        XCTAssertTrue(done.isComplete(p))
    }

    func testAnUnfinishedPackLeadsHomeForTwoDaysThenSettles() {
        let p = pack("p", release: "2026-09-16", items: 2)
        let none = WeekPackProgress(pack: p, results: [])
        XCTAssertTrue(WeekPackSchedule.leadsHome(p, progress: none, today: "2026-09-16"))
        XCTAssertTrue(WeekPackSchedule.leadsHome(p, progress: none, today: "2026-09-17"))
        XCTAssertFalse(WeekPackSchedule.leadsHome(p, progress: none, today: "2026-09-18"))
        XCTAssertFalse(WeekPackSchedule.leadsHome(p, progress: none, today: "2026-09-22"))
    }

    func testAStartedPackStillLeadsButAFinishedOneSettlesAtOnce() {
        let p = pack("p", release: "2026-09-16", items: 2)
        let started = WeekPackProgress(pack: p, results: [result(puzzleID: "p-0", correct: 5)])
        XCTAssertTrue(WeekPackSchedule.leadsHome(p, progress: started, today: "2026-09-16"))
        let finished = WeekPackProgress(pack: p, results: [result(puzzleID: "p-0", correct: 5),
                                                           result(puzzleID: "p-1", correct: 7)])
        XCTAssertFalse(WeekPackSchedule.leadsHome(p, progress: finished, today: "2026-09-16"))
    }

    func testLeadingCountsCalendarDaysAcrossAMonthEnd() {
        let p = pack("p", release: "2026-09-30", items: 1)
        let none = WeekPackProgress(pack: p, results: [])
        XCTAssertTrue(WeekPackSchedule.leadsHome(p, progress: none, today: "2026-10-01"))
        XCTAssertFalse(WeekPackSchedule.leadsHome(p, progress: none, today: "2026-10-02"))
    }

    func testShareTextIsSpoilerFreeAndCountsCards() {
        let p = pack("p", release: "2026-09-16", items: 2)
        let text = WeekPackProgress(pack: p, results: [result(puzzleID: "p-0", correct: 6),
                                                       result(puzzleID: "p-1", correct: 8)]).shareText(for: p)
        XCTAssertTrue(text.contains("🟩🟩🟩🟩🟩🟩⬛⬛"))
        XCTAssertTrue(text.contains("🟩🟩🟩🟩🟩🟩🟩🟩"))
        XCTAssertTrue(text.contains("14/16"))
        XCTAssertFalse(text.contains("P0"), "no player names in a shared recap")
    }

    func testDisplayTitleDropsThePacksOwnLabel() throws {
        let rows = try decodeItems([
            itemJSON(id: "a", pack: "p", ordinal: 0, theme: "2026 Week 1: top TE performances"),
            itemJSON(id: "b", pack: "p", ordinal: 1, theme: "CAR vs CHI, Sep 13, 2026: who had the better day?"),
        ])
        let items = rows.compactMap(\.item)
        XCTAssertEqual(items[0].displayTitle(packLabel: "2026 Week 1"), "Top TE performances")
        XCTAssertEqual(items[1].displayTitle(packLabel: "2026 Week 1"),
                       "CAR vs CHI, Sep 13, 2026: who had the better day?")
    }

    /// A feature's copy going missing from the catalog is invisible in English and total in
    /// Spanish (see `LocalizationTests`), so one key from each surface.
    func testPackCopyIsTranslated() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        let lookup = { (key: String) in es.localizedString(forKey: key, value: nil, table: "Localizable") }
        XCTAssertEqual(lookup("This week's pack"), "El pack de esta semana")
        XCTAssertEqual(lookup("GAME OF THE WEEK"), "PARTIDO DE LA SEMANA")
        XCTAssertEqual(lookup("%lld of %lld boards played"), "%lld de %lld tableros jugados")
    }

    func testPackIsAKnownPlayMode() {
        XCTAssertEqual(PlayMode(rawValue: "pack"), .pack)
        XCTAssertTrue(PlayMode.pack.countsForRecords)
    }

    private func result(puzzleID: String, correct: Int) -> GameResult {
        GameResult(playedAt: Date(), format: .keep4Normal, sport: .nfl, mode: .pack, ranked: false,
                   perfect: correct == 8, performance: Double(correct) / 8, score: 0, maxScore: 3000,
                   correct: correct, attempted: 8, durationMs: nil, ratingBefore: 1000,
                   ratingAfter: 1000, xpEarned: 0, streakAfter: 0, puzzleID: puzzleID,
                   details: GameResultDetails())
    }
}

final class WeekPackEngagementTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A private suite: hosted tests run inside the real app, and the standard defaults
        // would leak "opened" state into later manual launches (hosted-tests-pollute-sim).
        defaults = UserDefaults(suiteName: "WeekPackEngagementTests")
        defaults.removePersistentDomain(forName: "WeekPackEngagementTests")
    }

    func testAPackIsUnopenedUntilMarked() {
        XCTAssertFalse(WeekPackEngagement.engaged(defaults: defaults).contains("nfl-2026-wk01"))
        WeekPackEngagement.markEngaged("nfl-2026-wk01", defaults: defaults)
        XCTAssertTrue(WeekPackEngagement.engaged(defaults: defaults).contains("nfl-2026-wk01"))
    }

    func testMarkingTwiceStoresOnce() {
        WeekPackEngagement.markEngaged("a", defaults: defaults)
        WeekPackEngagement.markEngaged("a", defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "weekPackEngaged"), ["a"])
    }

    func testOldIDsAgeOut() {
        for i in 0..<60 { WeekPackEngagement.markEngaged("p\(i)", defaults: defaults) }
        let engaged = WeekPackEngagement.engaged(defaults: defaults)
        XCTAssertEqual(engaged.count, 40)
        XCTAssertTrue(engaged.contains("p59"))
        XCTAssertFalse(engaged.contains("p0"))
    }

    func testShortLabelAndBadgeDropTheYear() {
        let nfl = WeekPack(id: "n", sport: .nfl, label: "2026 Week 1", releaseDate: "2026-09-16", items: [])
        let mlb = WeekPack(id: "m", sport: .baseball, label: "Sep 7 to 13", releaseDate: "2026-09-17", items: [])
        XCTAssertEqual(nfl.shortLabel, "Week 1")
        XCTAssertEqual(nfl.badgeText, "WEEK 1 PACK")
        XCTAssertEqual(mlb.shortLabel, "Sep 7 to 13")
    }
}
