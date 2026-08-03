import XCTest
@testable import BallIQ

/// Builds one `GameResult` with sensible defaults, overriding only what a given test cares
/// about — the alternative is fifteen positional arguments repeated at every call site.
private func row(format: GameFormatKind = .keep4Normal, sport: Sport = .nfl, mode: PlayMode = .daily,
                 ranked: Bool = true, perfect: Bool = false, performance: Double = 0.5,
                 score: Int = 0, maxScore: Int = 0, attempted: Int = 0, correct: Int = 0,
                 durationMs: Int? = nil, ratingBefore: Int = 1200, ratingAfter: Int = 1200,
                 xpEarned: Int = 100, streakAfter: Int = 1,
                 playedAt: Date = GameLogFixtures.date(year: 2026, month: 1, day: 1),
                 puzzleID: String = "test", details: GameResultDetails = GameResultDetails()) -> GameResult {
    GameResult(playedAt: playedAt, format: format, sport: sport, mode: mode, ranked: ranked,
               perfect: perfect, performance: performance, score: score, maxScore: maxScore,
               correct: correct, attempted: attempted, durationMs: durationMs,
               ratingBefore: ratingBefore, ratingAfter: ratingAfter, xpEarned: xpEarned,
               streakAfter: streakAfter, puzzleID: puzzleID, details: details)
}

private func day(_ offset: Int, hour: Int = 12) -> Date {
    Calendar.current.date(byAdding: .day, value: offset,
                          to: GameLogFixtures.date(year: 2026, month: 1, day: 1, hour: hour))!
}

private func card(_ id: String, in cards: [StatCard]) -> StatCard? { cards.first { $0.id == id } }

final class CareerStatsTests: XCTestCase {

    // MARK: - CareerSummary

    func testCareerSummary_aggregatesAcrossRows() {
        let rows = GameLogFixtures.synthesize(days: 60, seed: 1)
        let summary = CareerSummary(rows)
        XCTAssertEqual(summary.games, rows.count)
        XCTAssertEqual(summary.cardsJudged, rows.reduce(0) { $0 + $1.attempted })
        XCTAssertEqual(summary.perfects, rows.filter(\.perfect).count)
        let correct = rows.reduce(0) { $0 + $1.correct }
        XCTAssertEqual(summary.accuracy ?? -1, Double(correct) / Double(summary.cardsJudged), accuracy: 0.0001)
        XCTAssertEqual(summary.firstPlayed, rows.map(\.playedAt).min())
        XCTAssertEqual(Set(summary.bySport.keys), Set(rows.map(\.sport)))
        XCTAssertEqual(Set(summary.byFormat.keys), Set(rows.map(\.format)))
    }

    func testCareerSummary_zeroRows() {
        let summary = CareerSummary([])
        XCTAssertEqual(summary.games, 0)
        XCTAssertEqual(summary.days, 0)
        XCTAssertEqual(summary.cardsJudged, 0)
        XCTAssertEqual(summary.perfects, 0)
        XCTAssertNil(summary.accuracy)
        XCTAssertEqual(summary.totalPlayMs, 0)
        XCTAssertNil(summary.firstPlayed)
        XCTAssertTrue(summary.bySport.isEmpty)
        XCTAssertTrue(summary.byFormat.isEmpty)
    }

    func testCareerSummary_oneRow() {
        let r = row(attempted: 4, correct: 3, durationMs: 12_000)
        let summary = CareerSummary([r])
        XCTAssertEqual(summary.games, 1)
        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.cardsJudged, 4)
        XCTAssertEqual(summary.accuracy, 0.75)
        XCTAssertEqual(summary.totalPlayMs, 12_000)
        XCTAssertEqual(summary.firstPlayed, r.playedAt)
        XCTAssertEqual(summary.bySport[.nfl]?.games, 1)
    }

    func testCareerSummary_allAttemptedZero_accuracyIsNil() {
        let rows = (0..<5).map { _ in row(format: .draftSpin, attempted: 0, correct: 0) }
        let summary = CareerSummary(rows)
        XCTAssertNil(summary.accuracy, "a Draft & Spin-only history has no accuracy concept — not 0%")
        XCTAssertEqual(summary.cardsJudged, 0)
        XCTAssertEqual(summary.games, 5)
    }

    func testFormatSplit_bestScore_respectsCountsForRecords() {
        let rows = [
            row(mode: .daily, score: 5, maxScore: 8),
            row(mode: .practice, score: 100, maxScore: 8),   // must not win "best"
            row(mode: .community, score: 100, maxScore: 8),  // must not win "best"
        ]
        XCTAssertEqual(FormatSplit(rows).bestScore, 5)
    }

    func testFormatSplit_bestScore_nilWhenOpenEnded() {
        let rows = [row(mode: .daily, score: 40, maxScore: 0)]
        XCTAssertNil(FormatSplit(rows).bestScore, "maxScore == 0 is open-ended, score/maxScore is meaningless")
    }

    // MARK: - CareerStatsMath

    func testDistinctDayCount() {
        let dates = [day(0), day(0, hour: 23), day(1), day(3)]
        XCTAssertEqual(CareerStatsMath.distinctDayCount(dates), 3)
    }

    func testLongestDailyStreak() {
        let dates = [day(0), day(1), day(2), day(5), day(6)]
        XCTAssertEqual(CareerStatsMath.longestDailyStreak(dates), 3)
    }

    func testLongestDailyStreak_empty() {
        XCTAssertEqual(CareerStatsMath.longestDailyStreak([]), 0)
    }

    func testLongestRun_perfectStreak() {
        let rows = [true, true, false, true, true, true, false].enumerated().map { i, perfect in
            row(perfect: perfect, playedAt: day(i))
        }
        XCTAssertEqual(CareerStatsMath.longestRun(rows) { $0.perfect }, 3)
    }

    func testLongestRun_sortsDefensively() {
        // Shuffled input order — the function must sort by playedAt itself.
        let rows = [
            row(perfect: true, playedAt: day(2)),
            row(perfect: true, playedAt: day(0)),
            row(perfect: true, playedAt: day(1)),
        ]
        XCTAssertEqual(CareerStatsMath.longestRun(rows) { $0.perfect }, 3)
    }

    func testConsistencyScore_perfectlySteady() {
        let rows = (0..<10).map { row(ranked: true, performance: 0.8, playedAt: day($0)) }
        XCTAssertEqual(CareerStatsMath.consistencyScore(rows) ?? -1, 1.0, accuracy: 0.0001)
    }

    func testConsistencyScore_wildlyInconsistent() {
        let rows = (0..<10).map { i in row(ranked: true, performance: i % 2 == 0 ? 0 : 1, playedAt: day(i)) }
        XCTAssertEqual(CareerStatsMath.consistencyScore(rows) ?? -1, 0.0, accuracy: 0.0001)
    }

    func testConsistencyScore_nilBelowThreeRows() {
        let rows = [row(ranked: true), row(ranked: true)]
        XCTAssertNil(CareerStatsMath.consistencyScore(rows))
    }

    func testConsistencyScore_ignoresUnranked() {
        let rows = [row(ranked: false), row(ranked: false), row(ranked: false)]
        XCTAssertNil(CareerStatsMath.consistencyScore(rows))
    }

    func testAccuracyByDayOfWeek_groupsCorrectly() {
        let sameWeekday = [row(attempted: 4, correct: 4, playedAt: day(0)),
                           row(attempted: 4, correct: 2, playedAt: day(7))]
        let weekday = Calendar.current.component(.weekday, from: day(0))
        let split = CareerStatsMath.accuracyByDayOfWeek(sameWeekday)[weekday]
        XCTAssertEqual(split?.attempted, 8)
        XCTAssertEqual(split?.correct, 6)
    }

    func testAccuracyByTimeOfDay_bucketsHours() {
        let rows = [row(attempted: 1, correct: 1, playedAt: day(0, hour: 6)),
                   row(attempted: 1, correct: 0, playedAt: day(0, hour: 23))]
        let byBucket = CareerStatsMath.accuracyByTimeOfDay(rows)
        XCTAssertEqual(byBucket[.earlyMorning]?.attempted, 1)
        XCTAssertEqual(byBucket[.lateNight]?.attempted, 1)
    }

    // MARK: - StatCatalog: one test per card

    func testCareerAccuracyCard() {
        let rows = [4, 4, 4, 4, 4].map { _ in 0 }.enumerated().map { i, _ -> GameResult in
            let correct = i < 3 ? 4 : 0
            return row(attempted: 4, correct: correct, playedAt: day(i))
        }
        let c = card("careerAccuracy", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "60%")
        XCTAssertEqual(c.context, "20 cards judged")
        XCTAssertTrue(c.isUnlocked)
        XCTAssertNotNil(c.flavor)
    }

    func testAccuracyBySportCards() {
        let rows = (0..<5).flatMap { i -> [GameResult] in
            [row(sport: .nfl, attempted: 4, correct: 2, playedAt: day(i)),
             row(sport: .nba, attempted: 4, correct: 4, playedAt: day(i))]
        }
        let cards = StatCatalog.cards(rows, scope: .all)
        XCTAssertEqual(card("accuracyBySport.nfl", in: cards)?.value, "50%")
        XCTAssertEqual(card("accuracyBySport.nba", in: cards)?.value, "100%")
        let untouched = card("accuracyBySport.baseball", in: cards)!
        XCTAssertEqual(untouched.value, "—")
        XCTAssertFalse(untouched.isUnlocked)
    }

    func testAccuracyBySportCards_omittedWhenScopedToOneSport() {
        let cards = StatCatalog.cards([row(sport: .nfl)], scope: .sport(.nfl))
        XCTAssertNil(card("accuracyBySport.nfl", in: cards))
    }

    func testAccuracyByFormatCards() {
        let rows = (0..<5).map { row(format: .whoAmI, attempted: 1, correct: 1, playedAt: day($0)) }
        let c = card("accuracyByFormat.whoAmI", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "100%")
        XCTAssertTrue(c.isUnlocked)
    }

    func testCutInstinctCard() {
        var details1 = GameResultDetails(); details1.missedKeepCount = 1; details1.missedCutCount = 0
        var details2 = GameResultDetails(); details2.missedKeepCount = 0; details2.missedCutCount = 1
        var details3 = GameResultDetails(); details3.missedKeepCount = 2; details3.missedCutCount = 1
        let rows = [
            row(format: .keep4Normal, details: details1),
            row(format: .keep4Hard, details: details2),
            row(format: .keep4Normal, details: details3),
        ]
        let c = card("cutInstinct", in: StatCatalog.cards(rows, scope: .all))!
        // missedKeep total 3, missedCut total 2, of 5 misses -> 40% were bad cuts.
        XCTAssertEqual(c.value, "40%")
        XCTAssertEqual(c.context, "2 bad cuts of 5 misses")
        XCTAssertNotNil(c.flavor, "trigger-happy band should have a flavor line")
    }

    func testCutInstinctCard_hoarderFlavorInterpolatesRealRate() {
        var d = GameResultDetails(); d.missedKeepCount = 4; d.missedCutCount = 1
        let rows = [row(format: .keep4Normal, details: d)]
        let c = card("cutInstinct", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "20%")
        XCTAssertNil(c.flavor, "20% is neither hoarder nor trigger-happy band")
    }

    func testCutInstinctCard_noKeep4Rows_isEmptyNotZero() {
        let rows = [row(format: .whoAmI)]
        let c = card("cutInstinct", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "—")
    }

    func testClueEfficiencyCards() {
        func whoAmI(solved: Bool, clues: Int) -> GameResult {
            var d = GameResultDetails(); d.solved = solved; d.cluesUsed = clues
            return row(format: .whoAmI, details: d)
        }
        let rows = [whoAmI(solved: true, clues: 1), whoAmI(solved: true, clues: 3),
                   whoAmI(solved: true, clues: 5), whoAmI(solved: false, clues: 6)]
        let cards = StatCatalog.cards(rows, scope: .all)
        XCTAssertEqual(card("clueEfficiencyAvg", in: cards)?.value, "3.0")
        XCTAssertEqual(card("clueEfficiencyFirstTry", in: cards)?.value, "33%")
    }

    func testClueEfficiencyCards_noSolves_isEmptyNotZero() {
        var d = GameResultDetails(); d.solved = false; d.cluesUsed = 6
        let cards = StatCatalog.cards([row(format: .whoAmI, details: d)], scope: .all)
        XCTAssertEqual(card("clueEfficiencyAvg", in: cards)?.value, "—")
        XCTAssertEqual(card("clueEfficiencyFirstTry", in: cards)?.value, "—")
    }

    func testDeepCutIndexCard() {
        var d1 = GameResultDetails(); d1.rarityStars = 10; d1.cellsSolved = 5
        var d2 = GameResultDetails(); d2.rarityStars = 4; d2.cellsSolved = 2
        let rows = [row(format: .grid, details: d1), row(format: .grid, details: d2)]
        let c = card("deepCutIndex", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "2.00★")
        XCTAssertEqual(c.flavor, "You live in the deep cuts — obscure names, no fear.")
    }

    func testOverBiasCards() {
        func ou(over: Int, overC: Int, under: Int, underC: Int) -> GameResult {
            var d = GameResultDetails()
            d.overPicks = over; d.overCorrect = overC; d.underPicks = under; d.underCorrect = underC
            return row(format: .overUnder, details: d)
        }
        let rows = [ou(over: 6, overC: 5, under: 4, underC: 0), ou(over: 2, overC: 1, under: 8, underC: 3)]
        let cards = StatCatalog.cards(rows, scope: .all)
        XCTAssertEqual(card("overBias", in: cards)?.value, "40%")
        XCTAssertEqual(card("overHitRate", in: cards)?.value, "75%")
        XCTAssertEqual(card("underHitRate", in: cards)?.value, "25%")
    }

    func testChampionshipRateCard() {
        func draft(_ outcome: String) -> GameResult {
            var d = GameResultDetails(); d.outcome = outcome
            return row(format: .draftSpin, details: d)
        }
        let rows = [draft("champion"), draft("champion"), draft("eliminated"), draft("playoffs")]
        let c = card("championshipRate", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "50%")
        XCTAssertEqual(c.context, "2 titles in 4 runs")
    }

    func testBestEverCards() {
        let rows = [
            row(format: .keep4Normal, mode: .daily, score: 5, maxScore: 8),
            row(format: .keep4Normal, mode: .daily, score: 8, maxScore: 8),
            row(format: .keep4Normal, mode: .daily, score: 3, maxScore: 8),
            row(format: .keep4Normal, mode: .practice, score: 100, maxScore: 8),   // excluded
        ]
        let c = card("bestEver.keep4Normal", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "8")
    }

    func testPerfectGamesCard() {
        let rows = [row(mode: .daily, perfect: true), row(mode: .daily, perfect: false),
                   row(mode: .daily, perfect: true), row(mode: .practice, perfect: true)]
        let c = card("perfectGames", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "2")
    }

    func testFastestPerfectCard() {
        let rows = [row(mode: .daily, perfect: true, durationMs: 5_000),
                   row(mode: .daily, perfect: true, durationMs: 3_000),
                   row(mode: .daily, perfect: true, durationMs: nil),
                   row(mode: .practice, perfect: true, durationMs: 1_000)]
        let c = card("fastestPerfect", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "0:03")
    }

    func testBiggestRatingJumpCard() {
        let rows = [row(mode: .daily, ratingBefore: 1200, ratingAfter: 1220),
                   row(mode: .daily, ratingBefore: 1220, ratingAfter: 1215),
                   row(mode: .daily, ratingBefore: 1215, ratingAfter: 1250),
                   row(mode: .practice, ratingBefore: 1000, ratingAfter: 1500)]
        let c = card("biggestRatingJump", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "+35")
    }

    func testBestDayCard() {
        let rows = [row(mode: .daily, score: 5, playedAt: day(0)),
                   row(mode: .daily, score: 7, playedAt: day(0, hour: 20)),
                   row(mode: .daily, score: 20, playedAt: day(1))]
        let c = card("bestDay", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "20")
    }

    func testLongestComboCard() {
        func ou(_ combo: Int) -> GameResult {
            var d = GameResultDetails(); d.bestCombo = combo
            return row(format: .overUnder, details: d)
        }
        let c = card("longestCombo", in: StatCatalog.cards([ou(3), ou(7), ou(2)], scope: .all))!
        XCTAssertEqual(c.value, "7")
    }

    func testLongestStreakCard() {
        let rows = [day(0), day(1), day(2), day(3), day(6)].map { row(playedAt: $0) }
        let c = card("longestStreak", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "4 days")
    }

    func testLongestPerfectRunCard() {
        let pattern = [true, true, false, true, true, true]
        let rows = pattern.enumerated().map { i, perfect in row(mode: .daily, perfect: perfect, playedAt: day(i)) }
        let c = card("longestPerfectRun", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "3 in a row")
    }

    func testMetronomeScoreCard() {
        let rows = (0..<10).map { row(ranked: true, performance: 0.8, playedAt: day($0)) }
        let c = card("metronomeScore", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "100%")
    }

    func testShowUpRateCard() {
        // Relative to "now" so this stays correct no matter when the suite runs.
        let offsets = [-9, -7, -5, -3, -1]
        let rows = offsets.map { row(playedAt: Calendar.current.date(byAdding: .day, value: $0, to: Date())!) }
        let c = card("showUpRate", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "50%")
        XCTAssertEqual(c.context, "5 of 10 days")
    }

    func testShowUpRateCard_zeroRows() {
        let c = card("showUpRate", in: StatCatalog.cards([], scope: .all))!
        XCTAssertEqual(c.value, "—")
    }

    func testDayOfWeekCard() {
        let base = GameLogFixtures.date(year: 2026, month: 2, day: 2)   // arbitrary Monday-ish anchor
        func sameWeekday(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n * 7, to: base)! }
        func otherWeekday(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: 1 + n * 7, to: base)! }
        let good = (0..<3).map { row(attempted: 4, correct: 4, playedAt: sameWeekday($0)) }
        let bad = (0..<3).map { row(attempted: 4, correct: 1, playedAt: otherWeekday($0)) }
        let c = card("dayOfWeek", in: StatCatalog.cards(good + bad, scope: .all))!
        let expectedWeekday = Calendar.current.component(.weekday, from: base)
        let expectedName = Calendar.current.standaloneWeekdaySymbols[expectedWeekday - 1]
        XCTAssertEqual(c.value, expectedName)
        XCTAssertEqual(c.context, "100%")
    }

    func testDayOfWeekCard_belowRepThreshold_isEmpty() {
        let rows = [row(attempted: 4, correct: 4)]
        let c = card("dayOfWeek", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "—")
    }

    func testTimeOfDayCard() {
        let good = (0..<3).map { row(attempted: 4, correct: 4, playedAt: day($0, hour: 6)) }
        let bad = (0..<3).map { row(attempted: 4, correct: 1, playedAt: day($0, hour: 23)) }
        let c = card("timeOfDay", in: StatCatalog.cards(good + bad, scope: .all))!
        XCTAssertEqual(c.value, TimeOfDayBucket.earlyMorning.label)
        XCTAssertEqual(c.context, "100%")
    }

    func testPlayMixCard() {
        let rows = (0..<5).map { row(format: .keep4Normal, playedAt: day($0)) }
            + (0..<3).map { row(format: .whoAmI, playedAt: day($0)) }
            + (0..<2).map { row(format: .grid, playedAt: day($0)) }
        let c = card("playMix", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "K4C4")
        XCTAssertEqual(c.context, "50% of your games")
    }

    func testPlayMixCard_zeroRows() {
        let c = card("playMix", in: StatCatalog.cards([], scope: .all))!
        XCTAssertEqual(c.value, "—")
    }

    func testAccuracyTrendCard() {
        let cold = (0..<5).map { row(attempted: 4, correct: 0, playedAt: day($0)) }
        let hot = (5..<15).map { row(attempted: 4, correct: 4, playedAt: day($0)) }
        let c = card("accuracyTrend", in: StatCatalog.cards(cold + hot, scope: .all))!
        XCTAssertEqual(c.value, "+33%")
        XCTAssertEqual(c.context, "last 10 vs career 67%")
    }

    func testAccuracyTrendCard_belowRepThreshold_isEmpty() {
        let rows = (0..<3).map { row(attempted: 4, correct: 4, playedAt: day($0)) }
        let c = card("accuracyTrend", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "—")
    }

    func testWhiteWhaleCard() {
        func miss(_ names: [String]) -> GameResult {
            var d = GameResultDetails(); d.missedPlayerNames = names
            return row(details: d)
        }
        let rows = [miss(["Jordan Addison", "CJ Stroud"]), miss(["Jordan Addison"]),
                   miss(["Jordan Addison", "Malik Nabers"]), miss(["Rome Odunze"]),
                   miss(["Jordan Addison", "Sam LaPorta"]), miss(["Jordan Addison"])]
        let c = card("whiteWhale", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "Jordan Addison")
        XCTAssertEqual(c.context, "missed 5×")
        XCTAssertTrue(c.flavor?.contains("Jordan Addison") ?? false)
    }

    func testWhiteWhaleCard_noMisses_isEmptyNotZero() {
        let c = card("whiteWhale", in: StatCatalog.cards([row()], scope: .all))!
        XCTAssertEqual(c.value, "—")
    }

    func testNemesisCategoryCard() {
        func grid(_ headers: [String]) -> GameResult {
            var d = GameResultDetails(); d.missedCellHeaders = headers
            return row(format: .grid, details: d)
        }
        let rows = [grid(["LAL"]), grid(["LAL", "MVP"]), grid(["All-Star"])]
        let c = card("nemesisCategory", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "LAL")
        XCTAssertEqual(c.context, "2 misses")
    }

    func testRideOrDieCard() {
        func draft(_ names: [String]) -> GameResult {
            var d = GameResultDetails(); d.draftedPlayerNames = names
            return row(format: .draftSpin, details: d)
        }
        let rows = [draft(["Ja'Marr Chase"]), draft(["Ja'Marr Chase", "Bijan Robinson"]), draft(["Tyreek Hill"])]
        let c = card("rideOrDie", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "Ja'Marr Chase")
        XCTAssertEqual(c.context, "drafted 2×")
    }

    func testNemesisSportCard() {
        let rows = (0..<3).map { row(sport: .nfl, attempted: 4, correct: 1, playedAt: day($0)) }
            + (0..<3).map { row(sport: .nba, attempted: 4, correct: 4, playedAt: day($0)) }
        let c = card("nemesisSport", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "NFL")
        XCTAssertEqual(c.context, "25%")
    }

    func testNemesisSportCard_omittedWhenScopedToOneSport() {
        let cards = StatCatalog.cards([row(sport: .nfl)], scope: .sport(.nfl))
        XCTAssertNil(card("nemesisSport", in: cards))
    }

    func testCardsJudgedCard() {
        let rows = [row(attempted: 1000), row(attempted: 234)]
        let c = card("cardsJudged", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "1,234")
    }

    func testTimeOnClockCard() {
        let rows = [row(durationMs: 3_600_000), row(durationMs: 100_000), row(durationMs: nil)]
        let c = card("timeOnClock", in: StatCatalog.cards(rows, scope: .all))!
        XCTAssertEqual(c.value, "1h 1m")
    }

    func testTimeOnClockCard_allNilDurations_isEmptyNotZero() {
        let c = card("timeOnClock", in: StatCatalog.cards([row(durationMs: nil)], scope: .all))!
        XCTAssertEqual(c.value, "—")
    }

    func testHighlights_respectsLimitAndUnlockStatus() {
        let rows = GameLogFixtures.synthesize(days: 400, seed: 7)
        let highlights = StatCatalog.highlights(rows, limit: 5)
        XCTAssertLessThanOrEqual(highlights.count, 5)
        XCTAssertTrue(highlights.allSatisfy(\.isUnlocked))
    }

    func testHighlights_emptyLog() {
        XCTAssertTrue(StatCatalog.highlights([]).isEmpty)
    }

    // MARK: - Degenerate cases

    func testZeroRows_everyAccessorIsSafe() {
        let summary = CareerSummary([])
        XCTAssertNil(summary.accuracy)
        for c in StatCatalog.cards([], scope: .all) {
            XCTAssertFalse(c.value.isEmpty)
            XCTAssertFalse(c.value.lowercased().contains("nan"))
            XCTAssertFalse(c.isUnlocked, "nothing should read as unlocked off zero reps")
        }
        for sport in Sport.allCases {
            XCTAssertTrue(StatCatalog.cards([], scope: .sport(sport)).allSatisfy { !$0.value.isEmpty })
        }
    }

    func testExactlyOneRow() {
        let rows = [row(format: .whoAmI, perfect: true, attempted: 1, correct: 1, durationMs: 8_000,
                        details: { var d = GameResultDetails(); d.solved = true; d.cluesUsed = 1; return d }())]
        // Must not crash, and single-sample stats should read as real values, not garbage.
        let cards = StatCatalog.cards(rows, scope: .all)
        XCTAssertEqual(card("cardsJudged", in: cards)?.value, "1")
        XCTAssertEqual(CareerSummary(rows).days, 1)
        XCTAssertNil(CareerStatsMath.consistencyScore(rows), "one ranked row is below the 3-row minimum")
    }

    func testAllPerfectHistory() {
        let rows = (0..<10).map { row(mode: .daily, perfect: true, attempted: 4, correct: 4,
                                      durationMs: 10_000 + $0 * 1000, playedAt: day($0)) }
        let cards = StatCatalog.cards(rows, scope: .all)
        XCTAssertEqual(card("perfectGames", in: cards)?.value, "10")
        XCTAssertEqual(card("longestPerfectRun", in: cards)?.value, "10 in a row")
        XCTAssertEqual(card("careerAccuracy", in: cards)?.value, "100%")
    }

    func testAllRowsAttemptedZero_pureDraftSpin() {
        let rows = (0..<8).map { row(format: .draftSpin, attempted: 0, correct: 0, playedAt: day($0)) }
        let cards = StatCatalog.cards(rows, scope: .all)
        XCTAssertEqual(card("careerAccuracy", in: cards)?.value, "—", "no attempts anywhere means no accuracy, not 0%")
        XCTAssertEqual(card("cardsJudged", in: cards)?.value, "0")
        XCTAssertNil(CareerSummary(rows).accuracy)
    }

    func testYearBoundaryAndDST_distinctDayMath() {
        var est = Calendar(identifier: .gregorian)
        est.timeZone = TimeZone(identifier: "America/New_York")!
        let rows = GameLogFixtures.yearBoundaryAndDSTRows()
        XCTAssertEqual(CareerStatsMath.distinctDayCount(rows.map(\.playedAt), calendar: est), 6)
        XCTAssertEqual(CareerStatsMath.longestDailyStreak(rows.map(\.playedAt), calendar: est), 3)
        XCTAssertEqual(CareerSummary(rows).days, CareerStatsMath.distinctDayCount(rows.map(\.playedAt)))
    }

    func testPracticeAndCommunityOnly_personalBestsAreEmptyNotZero() {
        let rows = [
            row(format: .keep4Normal, mode: .practice, perfect: true, score: 8, maxScore: 8,
               attempted: 8, correct: 8, durationMs: 2_000),
            row(format: .whoAmI, mode: .community, perfect: true, score: 6, maxScore: 6,
               attempted: 1, correct: 1, durationMs: 3_000),
            row(format: .grid, mode: .practice, score: 9, maxScore: 9, attempted: 9, correct: 9),
            row(format: .overUnder, mode: .community, score: 40, attempted: 10, correct: 6,
               details: { var d = GameResultDetails(); d.bestCombo = 12; return d }()),
        ]
        let cards = StatCatalog.cards(rows, scope: .all)
        for format in [GameFormatKind.keep4Normal, .whoAmI, .grid] {
            XCTAssertEqual(card("bestEver.\(format.rawValue)", in: cards)?.value, "—")
        }
        XCTAssertEqual(card("bestDay", in: cards)?.value, "—")
        XCTAssertEqual(card("longestCombo", in: cards)?.value, "—")
        XCTAssertEqual(card("fastestPerfect", in: cards)?.value, "—")
        XCTAssertEqual(card("biggestRatingJump", in: cards)?.value, "—")
        // Volume/accuracy stats are NOT records — they should still see these rows.
        XCTAssertEqual(card("cardsJudged", in: cards)?.value, "28")
    }
}
