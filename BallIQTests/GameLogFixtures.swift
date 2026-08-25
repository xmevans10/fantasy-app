import Foundation
@testable import BallIQ

/// A tiny linear congruential generator — deliberately *not* `Foundation`'s
/// `SystemRandomNumberGenerator`, which is explicitly non-reproducible even with a fixed seed.
/// `CareerStatsTests` needs the same `seed` to produce byte-identical fixtures on every run and
/// every machine, and an LCG's whole point is that `state` alone determines every future draw.
struct FixtureRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // A seed of 0 would leave the generator stuck at 0 forever (0 * anything + 0 == 0
        // after the first non-additive step never actually applies) — nudge it off zero.
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// Constants from Knuth's MMIX — a well-studied 64-bit LCG, good enough for fixture
    /// generation (nobody is trying to defeat this cryptographically).
    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / Double(1 << 53))   // [0, 1)
    }

    mutating func nextInt(_ range: Range<Int>) -> Int {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt64(span))
    }

    mutating func chance(_ probability: Double) -> Bool { nextDouble() < probability }

    mutating func choice<T>(_ items: [T]) -> T { items[nextInt(0..<items.count)] }
}

/// Deterministic synthetic career logs for `CareerStatsTests` — realistic enough (mixed
/// formats/sports/modes, plausible score ranges, some perfects, some practice reps) that the
/// stats built on top of them exercise real code paths, but always the *same* rows for a given
/// `(days, seed)` pair so assertions never flake.
enum GameLogFixtures {

    static let referenceStart = date(year: 2025, month: 11, day: 15, hour: 12, minute: 0)

    /// `days` calendar days starting at `start`, not every one of them played (a real career log
    /// has gaps), some days with more than one session.
    static func synthesize(days: Int, seed: UInt64 = 1, startingAt start: Date = referenceStart) -> [GameResult] {
        var rng = FixtureRNG(seed: seed)
        let calendar = Calendar.current
        var rows: [GameResult] = []
        var ratingBySport: [Sport: Int] = [:]

        for dayOffset in 0..<max(days, 0) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: start) else { continue }
            guard rng.chance(0.82) else { continue }   // most, not all, days get played
            let sessionCount = rng.chance(0.25) ? rng.nextInt(2..<4) : 1
            for session in 0..<sessionCount {
                let hour = rng.nextInt(6..<23)
                let minute = rng.nextInt(0..<60)
                guard let playedAt = calendar.date(bySettingHour: hour, minute: minute,
                                                   second: session, of: day) else { continue }
                let sport = rng.choice(Sport.allCases)
                let format = rng.choice(GameFormatKind.allCases)
                let mode: PlayMode = {
                    if rng.chance(0.12) { return .practice }
                    if rng.chance(0.07) { return .community }
                    return rng.choice([.daily, .versus, .dailyDraft, .archive])
                }()
                let before = ratingBySport[sport, default: 1200]
                let delta = rng.nextInt(-20..<41)   // wins outnumber losses, like a real ladder
                let after = max(100, before + delta)
                ratingBySport[sport] = after
                rows.append(makeRow(format: format, sport: sport, mode: mode, playedAt: playedAt,
                                    ratingBefore: before, ratingAfter: after, rng: &rng))
            }
        }
        return rows
    }

    /// One row shaped like whatever `format` actually produces — per-format score ranges and
    /// `GameResultDetails` payloads, so a test exercising (say) Deep-Cut Index sees Grid rows
    /// with `rarityStars`/`cellsSolved` actually populated rather than empty details.
    private static func makeRow(format: GameFormatKind, sport: Sport, mode: PlayMode, playedAt: Date,
                                ratingBefore: Int, ratingAfter: Int, rng: inout FixtureRNG) -> GameResult {
        var details = GameResultDetails()
        let score: Int, maxScore: Int, correct: Int, attempted: Int
        let perfect: Bool
        let performance: Double

        switch format {
        case .keep4Normal, .keep4Hard:
            attempted = 8
            correct = rng.nextInt(4..<9)
            maxScore = 8
            score = correct
            perfect = correct == attempted
            performance = Double(correct) / Double(attempted)
            if !perfect {
                let missedCut = rng.nextInt(0..<2)
                let missedKeep = attempted - correct - missedCut
                details.missedKeepCount = max(0, missedKeep)
                details.missedCutCount = missedCut
                details.missedPlayerNames = missedPlayerPool(rng: &rng, count: max(1, attempted - correct))
                details.missedPlayerIDs = details.missedPlayerNames?.map { $0.replacingOccurrences(of: " ", with: "-").lowercased() }
            }
            details.theme = "Best Season"

        case .whoAmI:
            attempted = 1
            let solved = rng.chance(0.8)
            let clues = solved ? rng.nextInt(1..<7) : 6
            correct = solved ? 1 : 0
            maxScore = 6
            score = solved ? max(0, 7 - clues) : 0
            perfect = solved && clues == 1
            performance = solved ? Double(7 - clues) / 6.0 : 0
            details.solved = solved
            details.cluesUsed = clues
            details.wrongGuesses = solved ? rng.nextInt(0..<2) : rng.nextInt(1..<4)
            details.answerName = whoAmIPool(rng: &rng)
            if !solved { details.missedPlayerNames = [details.answerName!] }

        case .journeyman:
            // Five guesses against a fully-visible career path — same shape as `.whoAmI` above,
            // which is the point: they share a scoring table, so a fixture that drifted from it
            // would quietly make cross-format analytics compare two different scales.
            attempted = 1
            let namedIt = rng.chance(0.75)
            let guesses = namedIt ? rng.nextInt(1..<6) : 5
            correct = namedIt ? 1 : 0
            maxScore = 5
            score = namedIt ? 6 - guesses : 0
            perfect = namedIt && guesses == 1
            performance = namedIt ? Double(6 - guesses) / 5.0 : 0
            details.solved = namedIt
            details.cluesUsed = guesses
            details.wrongGuesses = namedIt ? guesses - 1 : guesses
            details.answerName = whoAmIPool(rng: &rng)
            if !namedIt { details.missedPlayerNames = [details.answerName!] }

        case .overUnder:
            let picks = rng.nextInt(6..<15)
            let overPicks = rng.nextInt(0..<(picks + 1))
            let underPicks = picks - overPicks
            let overCorrect = rng.nextInt(0..<(overPicks + 1))
            let underCorrect = rng.nextInt(0..<(underPicks + 1))
            attempted = picks
            correct = overCorrect + underCorrect
            maxScore = 0   // open-ended
            score = correct
            perfect = correct == picks && picks > 0
            performance = picks > 0 ? Double(correct) / Double(picks) : 0
            details.overPicks = overPicks
            details.overCorrect = overCorrect
            details.underPicks = underPicks
            details.underCorrect = underCorrect
            details.bestCombo = rng.nextInt(0..<picks + 1)
            details.livesLeft = rng.nextInt(0..<4)

        case .blitz:
            // A whole timed run in one row (see `GameFormatKind.blitz`): `attempted`/`correct`
            // are boards served and boards cleared, and `maxScore` is what a flawless run of
            // that same sequence would have paid — so score/maxScore stays a real ratio here,
            // unlike the open-ended arcade rows below.
            let boards = rng.nextInt(3..<20)
            let clean = rng.nextInt(0..<(boards + 1))
            attempted = boards
            correct = clean
            maxScore = boards * 1000
            score = rng.nextInt(0..<(maxScore + 1))
            perfect = clean == boards
            performance = boards > 0 ? Double(clean) / Double(boards) : 0
            details.bestCombo = rng.nextInt(0..<(clean + 1))

        case .draftSpin:
            attempted = 0   // no right answers to attempt
            correct = 0
            maxScore = 0
            let wins = rng.nextInt(0..<8)
            let losses = rng.nextInt(0..<8)
            score = wins
            let champion = wins >= 6 && rng.chance(0.4)
            perfect = false
            performance = Double(wins) / Double(max(wins + losses, 1))
            details.outcome = champion ? "champion" : (wins > losses ? "playoffs" : "eliminated")
            details.wins = wins
            details.losses = losses
            details.totalPoints = rng.nextInt(400..<1600)
            details.draftedPlayerNames = draftPool(rng: &rng, count: 3)

        case .grid:
            attempted = 9
            let solved = rng.nextInt(3..<10)
            correct = solved
            maxScore = 9
            score = solved
            perfect = solved == 9
            performance = Double(solved) / 9.0
            details.cellsSolved = solved
            details.rarityStars = rng.nextInt(solved..<(solved * 3 + 1))
            if solved < 9 {
                details.missedCellHeaders = gridHeaderPool(rng: &rng, count: 9 - solved)
            }
        }

        let durationMs: Int? = rng.chance(0.9) ? rng.nextInt(15_000..<240_000) : nil

        return GameResult(
            playedAt: playedAt, format: format, sport: sport, mode: mode,
            ranked: mode == .daily || mode == .dailyDraft || mode == .versus,
            perfect: perfect, performance: min(max(performance, 0), 1),
            score: score, maxScore: maxScore, correct: correct, attempted: attempted,
            durationMs: durationMs, ratingBefore: ratingBefore, ratingAfter: ratingAfter,
            xpEarned: rng.nextInt(50..<250), streakAfter: rng.nextInt(0..<40),
            puzzleID: "\(format.rawValue)-\(sport.rawValue)-\(Int(playedAt.timeIntervalSince1970))",
            details: details)
    }

    // MARK: - Name pools (small, deterministic, plausible-sounding)

    private static let missedPlayers = ["Jordan Addison", "CJ Stroud", "Malik Nabers", "Brock Purdy",
                                        "Sam LaPorta", "De'Von Achane", "Puka Nacua", "Rome Odunze"]
    private static let whoAmIAnswers = ["Patrick Mahomes", "Victor Wembanyama", "Shohei Ohtani",
                                        "Erling Haaland", "Novak Djokovic", "Caitlin Clark"]
    private static let draftPlayers = ["Ja'Marr Chase", "Bijan Robinson", "Amon-Ra St. Brown",
                                       "Jalen Hurts", "Christian McCaffrey", "Tyreek Hill"]
    private static let gridHeaders = ["LAL", "30+ PPG season", "All-Star", "MVP", "Draft lottery",
                                      "Traded midseason", "Rookie of the Year"]

    private static func missedPlayerPool(rng: inout FixtureRNG, count: Int) -> [String] {
        (0..<max(count, 0)).map { _ in rng.choice(missedPlayers) }
    }

    private static func whoAmIPool(rng: inout FixtureRNG) -> String { rng.choice(whoAmIAnswers) }

    private static func draftPool(rng: inout FixtureRNG, count: Int) -> [String] {
        (0..<count).map { _ in rng.choice(draftPlayers) }
    }

    private static func gridHeaderPool(rng: inout FixtureRNG, count: Int) -> [String] {
        (0..<max(count, 0)).map { _ in rng.choice(gridHeaders) }
    }

    // MARK: - Date helpers

    static func date(year: Int, month: Int, day: Int, hour: Int = 12, minute: Int = 0,
                     timeZone: TimeZone = .current) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)!
    }

    /// A hand-built log that specifically straddles a year boundary (Dec 31 → Jan 1) and a US
    /// DST transition (spring-forward, where 2:00–2:59 AM local doesn't exist), so
    /// `CareerStatsTests` can assert the day-counting math doesn't get confused by either —
    /// `synthesize` alone can't guarantee hitting these exact dates without hardcoding them.
    static func yearBoundaryAndDSTRows() -> [GameResult] {
        var rng = FixtureRNG(seed: 99)
        let est = TimeZone(identifier: "America/New_York")!
        let dstDates: [Date] = [
            date(year: 2025, month: 12, day: 31, hour: 22, minute: 0, timeZone: est),
            date(year: 2026, month: 1, day: 1, hour: 1, minute: 0, timeZone: est),
            date(year: 2026, month: 1, day: 2, hour: 9, minute: 0, timeZone: est),
            // US spring-forward 2026-03-08: 2:00 AM jumps to 3:00 AM local.
            date(year: 2026, month: 3, day: 7, hour: 23, minute: 0, timeZone: est),
            date(year: 2026, month: 3, day: 8, hour: 9, minute: 0, timeZone: est),
            date(year: 2026, month: 3, day: 9, hour: 9, minute: 0, timeZone: est),
        ]
        return dstDates.map {
            makeRow(format: .keep4Normal, sport: .nfl, mode: .daily, playedAt: $0,
                   ratingBefore: 1200, ratingAfter: 1210, rng: &rng)
        }
    }
}
