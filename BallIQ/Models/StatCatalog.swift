import Foundation

/// One tile on the career-stats screen. `StatCatalog` produces these; a view only ever reads
/// them — see the module doc on `StatCatalog` for why the computation lives here and not there.
struct StatCard: Identifiable, Equatable {
    enum Kind: Equatable { case number, percent, duration, fact, record }

    let id: String
    /// e.g. "CAREER ACCURACY".
    let title: String
    /// e.g. "76%" — always self-contained and readable alone, never needs `title` to make sense.
    let value: String
    /// A supporting fragment, e.g. "4,128 cards judged". Nil when there's nothing worth adding.
    let context: String?
    /// The delight surface — a personality-forward line about the stat, e.g. "You're a hoarder —
    /// most of your misses are keeps you should've cut." Nil for stats that don't earn one
    /// (a flat number rarely does; a lopsided rate almost always does).
    let flavor: String?
    let kind: Kind
    /// Progressive-unlock threshold — the rep count (games, solves, whatever the stat is *of*)
    /// needed before this card is worth showing un-blurred.
    let minReps: Int
    let repsSoFar: Int
    var isUnlocked: Bool { repsSoFar >= minReps }
}

/// What slice of the career log a set of cards is computed over.
enum StatScope: Equatable {
    case all
    case sport(Sport)

    fileprivate func filter(_ rows: [GameResult]) -> [GameResult] {
        switch self {
        case .all: return rows
        case .sport(let sport): return rows.filter { $0.sport == sport }
        }
    }
}

/// Turns a career log into the tiles the stats screen renders — every card the personal-
/// analytics feature knows how to compute, scoped either to a player's whole history or to one
/// sport. Pure: no I/O, no `RepositoryContainer`. A view (a later phase) calls `cards`/
/// `highlights` with whatever `GameLogRepository.all()` returned and renders what comes back.
///
/// Deliberately silent about cross-user data (percentile rank, "top 1% of players") — that
/// needs a server aggregate this layer has no way to reach, and is scoped to a later phase.
enum StatCatalog {

    /// Every card for `scope`, unlocked or not — the view decides how to render a locked one
    /// (blurred value, a "3 more games to unlock" caption), so a card is always returned rather
    /// than omitted for lack of data. A card's `value`/`context` reflect the real underlying
    /// numbers even while locked; only `isUnlocked` gates whether a view should show them.
    static func cards(_ rows: [GameResult], scope: StatScope) -> [StatCard] {
        let scoped = scope.filter(rows)
        var out: [StatCard] = []

        out.append(careerAccuracyCard(scoped))
        if scope == .all { out.append(contentsOf: accuracyBySportCards(rows)) }
        out.append(contentsOf: accuracyByFormatCards(scoped))
        out.append(cutInstinctCard(scoped))
        out.append(contentsOf: clueEfficiencyCards(scoped))
        out.append(deepCutIndexCard(scoped))
        out.append(contentsOf: overBiasCards(scoped))
        out.append(championshipRateCard(scoped))

        out.append(contentsOf: bestEverCards(scoped))
        out.append(perfectGamesCard(scoped))
        out.append(fastestPerfectCard(scoped))
        out.append(biggestRatingJumpCard(scoped))
        out.append(bestDayCard(scoped))
        out.append(longestComboCard(scoped))

        out.append(longestStreakCard(scoped))
        out.append(longestPerfectRunCard(scoped))
        out.append(metronomeScoreCard(scoped))
        out.append(showUpRateCard(scoped))

        out.append(dayOfWeekCard(scoped))
        out.append(timeOfDayCard(scoped))
        out.append(playMixCard(scoped))
        out.append(accuracyTrendCard(scoped))

        out.append(whiteWhaleCard(scoped))
        out.append(nemesisCategoryCard(scoped))
        out.append(rideOrDieCard(scoped))
        if scope == .all { out.append(nemesisSportCard(rows)) }
        out.append(cardsJudgedCard(scoped))
        out.append(timeOnClockCard(scoped))

        return out
    }

    /// The most-interesting *unlocked* cards, for a compact "highlights" surface (e.g. a share
    /// card or Home's post-game recap) that can't show all ~30 tiles at once. Facts and records
    /// read as inherently highlight-worthy; a rate/percent is only interesting when it's extreme
    /// (76% career accuracy isn't a headline, 34% or 98% is), so those are ranked by distance
    /// from a "boring" 50%. This is a judgment call, not a spec'd formula — there's no ground
    /// truth for "interesting" here.
    static func highlights(_ rows: [GameResult], limit: Int = 5) -> [StatCard] {
        let unlocked = cards(rows, scope: .all).filter(\.isUnlocked)
        func score(_ card: StatCard) -> Double {
            switch card.kind {
            case .fact, .record: return 1
            case .percent: return parsePercent(card.value).map { abs($0 - 0.5) * 2 } ?? 0
            case .duration, .number: return 0.3
            }
        }
        return Array(
            unlocked
                .sorted { a, b in
                    let sa = score(a), sb = score(b)
                    if sa != sb { return sa > sb }
                    return a.id < b.id   // stable, deterministic tie-break
                }
                .prefix(limit)
        )
    }

    // MARK: - Rates

    private static func careerAccuracyCard(_ rows: [GameResult]) -> StatCard {
        let attempted = rows.reduce(into: 0) { $0 += $1.attempted }
        let correct = rows.reduce(into: 0) { $0 += $1.correct }
        let accuracy: Double? = attempted > 0 ? Double(correct) / Double(attempted) : nil
        return StatCard(
            id: "careerAccuracy", title: String(localized: "CAREER ACCURACY"),
            value: Fmt.percent(accuracy),
            context: attempted > 0 ? String(localized: "\(Fmt.grouped(attempted)) cards judged") : nil,
            flavor: accuracyFlavor(accuracy), kind: .percent, minReps: 5, repsSoFar: rows.count)
    }

    private static func accuracyFlavor(_ accuracy: Double?) -> String? {
        guard let accuracy else { return nil }
        switch accuracy {
        case 0.9...:      return String(localized: "Elite. You're not guessing, you're grading the pros.")
        case 0.75..<0.9:  return String(localized: "Sharp — most rooms would take this deal.")
        case 0.6..<0.75:  return String(localized: "Solid. More right than wrong, every time out.")
        case 0.4..<0.6:   return String(localized: "A coin flip with better vibes.")
        default:          return String(localized: "Rebuilding year. Every dynasty starts somewhere.")
        }
    }

    private static func accuracyBySportCards(_ rows: [GameResult]) -> [StatCard] {
        Sport.allCases.map { sport in
            let split = FormatSplit(rows.filter { $0.sport == sport })
            return StatCard(
                id: "accuracyBySport.\(sport.rawValue)",
                title: String(localized: "\(sport.displayName.uppercased()) ACCURACY"),
                value: Fmt.percent(split.accuracy),
                context: split.attempted > 0 ? String(localized: "\(Fmt.grouped(split.attempted)) cards judged") : nil,
                flavor: nil, kind: .percent, minReps: 5, repsSoFar: split.games)
        }
    }

    private static func accuracyByFormatCards(_ rows: [GameResult]) -> [StatCard] {
        GameFormatKind.allCases.map { format in
            let split = FormatSplit(rows.filter { $0.format == format })
            return StatCard(
                id: "accuracyByFormat.\(format.rawValue)",
                title: String(localized: "\(format.displayName.uppercased()) ACCURACY"),
                value: Fmt.percent(split.accuracy),
                context: split.attempted > 0 ? String(localized: "\(Fmt.grouped(split.attempted)) cards judged") : nil,
                flavor: nil, kind: .percent, minReps: 5, repsSoFar: split.games)
        }
    }

    /// Keep4-only: of every miss (a bad keep or a bad cut), what share were bad cuts — see
    /// `GameResultDetails.missedKeepCount`/`missedCutCount` for which is which. High ⇒ most
    /// misses are cutting someone who should've stayed (trigger-happy); low ⇒ most misses are
    /// keeping someone who should've gone (hoarder).
    private static func cutInstinctCard(_ rows: [GameResult]) -> StatCard {
        let keep4 = rows.filter { $0.format == .keep4Normal || $0.format == .keep4Hard }
        let missedKeep = keep4.reduce(into: 0) { $0 += $1.details.missedKeepCount ?? 0 }
        let missedCut = keep4.reduce(into: 0) { $0 += $1.details.missedCutCount ?? 0 }
        let total = missedKeep + missedCut
        let rate: Double? = total > 0 ? Double(missedCut) / Double(total) : nil
        return StatCard(
            id: "cutInstinct", title: String(localized: "CUT INSTINCT"), value: Fmt.percent(rate),
            context: total > 0 ? String(localized: "\(Fmt.plain(missedCut)) bad cuts of \(Fmt.plain(total)) misses") : nil,
            flavor: cutInstinctFlavor(rate), kind: .percent, minReps: 5, repsSoFar: keep4.count)
    }

    /// Bands read on `rate` = share of misses that were bad *cuts* (cutting someone who
    /// should've stayed) — so high rate is trigger-happy, low rate is hoarder, with a neutral
    /// 20%–40% gap in between where neither read is strong enough to be worth saying out loud.
    private static func cutInstinctFlavor(_ rate: Double?) -> String? {
        guard let rate else { return nil }
        if rate >= 0.4 { return String(localized: "Trigger-happy — \(Fmt.percent(rate)) of your misses are good ones you cut loose. Trust the roster.") }
        if rate < 0.2 { return String(localized: "You're a hoarder — you keep more busts than you cut good ones.") }
        return nil
    }

    private static func clueEfficiencyCards(_ rows: [GameResult]) -> [StatCard] {
        let whoAmI = rows.filter { $0.format == .whoAmI }
        let solved = whoAmI.filter { $0.details.solved == true }
        let avgClues: Double? = solved.isEmpty ? nil :
            Double(solved.reduce(into: 0) { $0 += $1.details.cluesUsed ?? 0 }) / Double(solved.count)
        let firstTry = solved.filter { ($0.details.cluesUsed ?? .max) <= 1 }.count
        let firstTryRate: Double? = solved.isEmpty ? nil : Double(firstTry) / Double(solved.count)

        let avgCard = StatCard(
            id: "clueEfficiencyAvg", title: String(localized: "AVG CLUES USED"),
            value: avgClues.map { String(format: "%.1f", $0) } ?? "—",
            context: solved.isEmpty ? nil : String(localized: "over \(Fmt.plain(solved.count)) solves"),
            flavor: nil, kind: .number, minReps: 5, repsSoFar: whoAmI.count)
        let firstCard = StatCard(
            id: "clueEfficiencyFirstTry", title: String(localized: "FIRST-CLUE RATE"),
            value: Fmt.percent(firstTryRate),
            context: solved.isEmpty ? nil : String(localized: "\(Fmt.plain(firstTry)) of \(Fmt.plain(solved.count)) solves"),
            flavor: nil, kind: .percent, minReps: 5, repsSoFar: whoAmI.count)
        return [avgCard, firstCard]
    }

    /// Grid-only: rarity stars earned per cell solved — a proxy for "how obscure are the names
    /// you reach for" rather than sticking to the chalk (obvious/high-population) square.
    private static func deepCutIndexCard(_ rows: [GameResult]) -> StatCard {
        let grid = rows.filter { $0.format == .grid }
        let stars = grid.reduce(into: 0) { $0 += $1.details.rarityStars ?? 0 }
        let cells = grid.reduce(into: 0) { $0 += $1.details.cellsSolved ?? 0 }
        let index: Double? = cells > 0 ? Double(stars) / Double(cells) : nil
        return StatCard(
            id: "deepCutIndex", title: String(localized: "DEEP-CUT INDEX"),
            value: index.map { String(format: "%.2f★", $0) } ?? "—",
            context: cells > 0 ? String(localized: "\(Fmt.plain(cells)) cells solved") : nil,
            flavor: deepCutFlavor(index), kind: .number, minReps: 3, repsSoFar: grid.count)
    }

    private static func deepCutFlavor(_ index: Double?) -> String? {
        guard let index else { return nil }
        if index >= 1.5 { return String(localized: "You live in the deep cuts — obscure names, no fear.") }
        if index <= 0.5 { return String(localized: "Chalk player — you take the obvious square every time.") }
        return nil
    }

    private static func overBiasCards(_ rows: [GameResult]) -> [StatCard] {
        let ou = rows.filter { $0.format == .overUnder }
        let overPicks = ou.reduce(into: 0) { $0 += $1.details.overPicks ?? 0 }
        let overCorrect = ou.reduce(into: 0) { $0 += $1.details.overCorrect ?? 0 }
        let underPicks = ou.reduce(into: 0) { $0 += $1.details.underPicks ?? 0 }
        let underCorrect = ou.reduce(into: 0) { $0 += $1.details.underCorrect ?? 0 }
        let totalPicks = overPicks + underPicks
        let overBias: Double? = totalPicks > 0 ? Double(overPicks) / Double(totalPicks) : nil
        let overHit: Double? = overPicks > 0 ? Double(overCorrect) / Double(overPicks) : nil
        let underHit: Double? = underPicks > 0 ? Double(underCorrect) / Double(underPicks) : nil

        let bias = StatCard(
            id: "overBias", title: String(localized: "OVER BIAS"), value: Fmt.percent(overBias),
            context: totalPicks > 0 ? String(localized: "\(Fmt.plain(overPicks)) overs, \(Fmt.plain(underPicks)) unders") : nil,
            flavor: nil, kind: .percent, minReps: 5, repsSoFar: ou.count)
        let overCard = StatCard(
            id: "overHitRate", title: String(localized: "OVER HIT RATE"), value: Fmt.percent(overHit),
            context: nil, flavor: nil, kind: .percent, minReps: 5, repsSoFar: ou.count)
        let underCard = StatCard(
            id: "underHitRate", title: String(localized: "UNDER HIT RATE"), value: Fmt.percent(underHit),
            context: nil, flavor: nil, kind: .percent, minReps: 5, repsSoFar: ou.count)
        return [bias, overCard, underCard]
    }

    private static func championshipRateCard(_ rows: [GameResult]) -> StatCard {
        let draft = rows.filter { $0.format == .draftSpin }
        let champs = draft.filter { $0.details.outcome == "champion" }.count
        let rate: Double? = draft.isEmpty ? nil : Double(champs) / Double(draft.count)
        return StatCard(
            id: "championshipRate", title: String(localized: "CHAMPIONSHIP RATE"), value: Fmt.percent(rate),
            context: draft.isEmpty ? nil : String(localized: "\(Fmt.plain(champs)) titles in \(Fmt.plain(draft.count)) runs"),
            flavor: nil, kind: .percent, minReps: 5, repsSoFar: draft.count)
    }

    // MARK: - Records

    /// Formats with a meaningful closed-ended `maxScore`. Over/Under and Draft & Spin are
    /// open-ended (`maxScore == 0` by construction) so "best score" isn't well-defined for
    /// them — they get their own records instead (Longest Combo, Championship Rate).
    private static let scoredFormats: [GameFormatKind] = [.keep4Normal, .keep4Hard, .whoAmI, .grid]

    private static func bestEverCards(_ rows: [GameResult]) -> [StatCard] {
        scoredFormats.map { format in
            let eligible = rows.filter { $0.format == format && $0.mode.countsForRecords && $0.maxScore > 0 }
            let best = eligible.map(\.score).max()
            return StatCard(
                id: "bestEver.\(format.rawValue)", title: String(localized: "BEST \(format.displayName.uppercased())"),
                value: best.map(Fmt.grouped) ?? "—", context: nil, flavor: nil,
                kind: .record, minReps: 1, repsSoFar: eligible.count)
        }
    }

    private static func perfectGamesCard(_ rows: [GameResult]) -> StatCard {
        let eligible = rows.filter { $0.mode.countsForRecords }
        let perfects = eligible.filter(\.perfect).count
        return StatCard(
            id: "perfectGames", title: String(localized: "PERFECT GAMES"), value: Fmt.grouped(perfects),
            context: nil, flavor: perfects >= 25 ? String(localized: "A wall of perfects. Pitchers throw no-hitters less often than this.") : nil,
            kind: .record, minReps: 1, repsSoFar: eligible.count)
    }

    private static func fastestPerfectCard(_ rows: [GameResult]) -> StatCard {
        let perfects = rows.filter { $0.perfect && $0.mode.countsForRecords }
        let fastest = perfects.compactMap(\.durationMs).min()
        return StatCard(
            id: "fastestPerfect", title: String(localized: "FASTEST PERFECT"),
            value: fastest.map { Fmt.shortDuration(ms: $0) } ?? "—",
            context: nil, flavor: nil, kind: .duration, minReps: 1, repsSoFar: perfects.count)
    }

    private static func biggestRatingJumpCard(_ rows: [GameResult]) -> StatCard {
        let eligible = rows.filter { $0.mode.countsForRecords }
        let jump = eligible.map(\.ratingDelta).max()
        return StatCard(
            id: "biggestRatingJump", title: String(localized: "BIGGEST JUMP"),
            value: jump.map { $0 >= 0 ? "+\(Fmt.plain($0))" : Fmt.plain($0) } ?? "—",
            context: nil, flavor: nil, kind: .record, minReps: 1, repsSoFar: eligible.count)
    }

    private static func bestDayCard(_ rows: [GameResult], calendar: Calendar = .current) -> StatCard {
        let eligible = rows.filter { $0.mode.countsForRecords }
        let totals = Dictionary(grouping: eligible) { calendar.startOfDay(for: $0.playedAt) }
            .mapValues { $0.reduce(into: 0) { $0 += $1.score } }
        let best = totals.values.max()
        return StatCard(
            id: "bestDay", title: String(localized: "BEST DAY"), value: best.map(Fmt.grouped) ?? "—",
            context: nil, flavor: nil, kind: .record, minReps: 1, repsSoFar: eligible.count)
    }

    private static func longestComboCard(_ rows: [GameResult]) -> StatCard {
        let combos = rows.filter { $0.format == .overUnder && $0.mode.countsForRecords }.compactMap { $0.details.bestCombo }
        return StatCard(
            id: "longestCombo", title: String(localized: "LONGEST COMBO"),
            value: combos.max().map(Fmt.plain) ?? "—", context: nil, flavor: nil,
            kind: .record, minReps: 1, repsSoFar: combos.count)
    }

    // MARK: - Consistency

    private static func longestStreakCard(_ rows: [GameResult]) -> StatCard {
        let streak = CareerStatsMath.longestDailyStreak(rows.map(\.playedAt))
        return StatCard(
            id: "longestStreak", title: String(localized: "LONGEST STREAK"),
            value: String(localized: "\(Fmt.plain(streak)) days"), context: nil, flavor: nil,
            kind: .record, minReps: 1, repsSoFar: rows.count)
    }

    private static func longestPerfectRunCard(_ rows: [GameResult]) -> StatCard {
        let eligible = rows.filter { $0.mode.countsForRecords }
        let run = CareerStatsMath.longestRun(eligible) { $0.perfect }
        return StatCard(
            id: "longestPerfectRun", title: String(localized: "LONGEST PERFECT RUN"),
            value: String(localized: "\(Fmt.plain(run)) in a row"), context: nil, flavor: nil,
            kind: .record, minReps: 1, repsSoFar: eligible.count)
    }

    private static func metronomeScoreCard(_ rows: [GameResult]) -> StatCard {
        let ranked = rows.filter(\.ranked)
        let score = CareerStatsMath.consistencyScore(rows, lastN: 20)
        return StatCard(
            id: "metronomeScore", title: String(localized: "METRONOME SCORE"), value: Fmt.percent(score),
            context: nil, flavor: nil, kind: .percent, minReps: 3, repsSoFar: ranked.count)
    }

    /// Distinct days played divided by days since the first-ever recorded session — "how often
    /// do you actually show up once you've started". `today` is injectable for testability; the
    /// only impurity in this whole catalog, unavoidable for a stat defined relative to "now".
    private static func showUpRateCard(_ rows: [GameResult], calendar: Calendar = .current, today: Date = Date()) -> StatCard {
        guard let first = rows.map(\.playedAt).min() else {
            return StatCard(id: "showUpRate", title: String(localized: "SHOW-UP RATE"), value: "—",
                            context: nil, flavor: nil, kind: .percent, minReps: 5, repsSoFar: 0)
        }
        let distinctDays = CareerStatsMath.distinctDayCount(rows.map(\.playedAt), calendar: calendar)
        let daysSinceFirst = (calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                                       to: calendar.startOfDay(for: today)).day ?? 0) + 1
        let rate: Double? = daysSinceFirst > 0 ? Double(distinctDays) / Double(daysSinceFirst) : nil
        return StatCard(
            id: "showUpRate", title: String(localized: "SHOW-UP RATE"), value: Fmt.percent(rate),
            context: String(localized: "\(Fmt.plain(distinctDays)) of \(Fmt.plain(daysSinceFirst)) days"),
            flavor: nil, kind: .percent, minReps: 5, repsSoFar: rows.count)
    }

    // MARK: - Patterns

    private static func dayOfWeekCard(_ rows: [GameResult], calendar: Calendar = .current) -> StatCard {
        let byDay = CareerStatsMath.accuracyByDayOfWeek(rows, calendar: calendar)
        let qualifying = byDay.filter { $0.value.attempted >= 10 }
        let best = qualifying.sorted { a, b in
            let accA = a.value.accuracy ?? 0, accB = b.value.accuracy ?? 0
            return accA != accB ? accA > accB : a.key < b.key   // deterministic tie-break
        }.first
        let reps = rows.reduce(into: 0) { $0 += $1.attempted }
        guard let best, let acc = best.value.accuracy else {
            return StatCard(id: "dayOfWeek", title: String(localized: "BEST DAY OF WEEK"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 10, repsSoFar: reps)
        }
        return StatCard(
            id: "dayOfWeek", title: String(localized: "BEST DAY OF WEEK"),
            value: weekdayName(best.key, calendar: calendar), context: Fmt.percent(acc),
            flavor: nil, kind: .fact, minReps: 10, repsSoFar: reps)
    }

    private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let symbols = calendar.standaloneWeekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return "—" }
        return symbols[weekday - 1]
    }

    private static func timeOfDayCard(_ rows: [GameResult], calendar: Calendar = .current) -> StatCard {
        let byBucket = CareerStatsMath.accuracyByTimeOfDay(rows, calendar: calendar)
        let qualifying = byBucket.filter { $0.value.attempted >= 10 }
        let order = TimeOfDayBucket.allCases
        let best = qualifying.sorted { a, b in
            let accA = a.value.accuracy ?? 0, accB = b.value.accuracy ?? 0
            if accA != accB { return accA > accB }
            return (order.firstIndex(of: a.key) ?? 0) < (order.firstIndex(of: b.key) ?? 0)
        }.first
        let reps = rows.reduce(into: 0) { $0 += $1.attempted }
        guard let best, let acc = best.value.accuracy else {
            return StatCard(id: "timeOfDay", title: String(localized: "BEST TIME OF DAY"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 10, repsSoFar: reps)
        }
        return StatCard(
            id: "timeOfDay", title: String(localized: "BEST TIME OF DAY"),
            value: best.key.label, context: Fmt.percent(acc), flavor: nil, kind: .fact, minReps: 10, repsSoFar: reps)
    }

    private static func playMixCard(_ rows: [GameResult]) -> StatCard {
        guard !rows.isEmpty else {
            return StatCard(id: "playMix", title: String(localized: "FAVORITE FORMAT"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 5, repsSoFar: 0)
        }
        let counts = Dictionary(grouping: rows, by: \.format).mapValues(\.count)
        let top = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key.rawValue < b.key.rawValue
        }.first!
        let share = Double(top.value) / Double(rows.count)
        return StatCard(
            id: "playMix", title: String(localized: "FAVORITE FORMAT"), value: top.key.displayName,
            context: String(localized: "\(Fmt.percent(share)) of your games"),
            flavor: nil, kind: .fact, minReps: 5, repsSoFar: rows.count)
    }

    /// Rolling-10 accuracy against career accuracy — a coarse "are you hot right now" signal.
    private static func accuracyTrendCard(_ rows: [GameResult]) -> StatCard {
        let judged = rows.filter { $0.attempted > 0 }.sorted { $0.playedAt < $1.playedAt }
        let recent = Array(judged.suffix(10))
        let recentAcc = accuracy(of: recent)
        let careerAcc = accuracy(of: judged)
        guard let recentAcc, let careerAcc, recent.count >= 5 else {
            return StatCard(id: "accuracyTrend", title: String(localized: "HOT OR COLD"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 10, repsSoFar: judged.count)
        }
        let deltaPct = Int(((recentAcc - careerAcc) * 100).rounded())
        let value: String
        if deltaPct == 0 { value = String(localized: "Steady") }
        else if deltaPct > 0 { value = "+\(Fmt.plain(deltaPct))%" }
        else { value = "\(Fmt.plain(deltaPct))%" }
        return StatCard(
            id: "accuracyTrend", title: String(localized: "HOT OR COLD"), value: value,
            context: String(localized: "last 10 vs career \(Fmt.percent(careerAcc))"),
            flavor: nil, kind: .fact, minReps: 10, repsSoFar: judged.count)
    }

    private static func accuracy(of rows: [GameResult]) -> Double? {
        let attempted = rows.reduce(into: 0) { $0 += $1.attempted }
        guard attempted > 0 else { return nil }
        let correct = rows.reduce(into: 0) { $0 += $1.correct }
        return Double(correct) / Double(attempted)
    }

    // MARK: - Fun facts

    private static func whiteWhaleCard(_ rows: [GameResult]) -> StatCard {
        let names = rows.flatMap { $0.details.missedPlayerNames ?? [] }
        guard let top = mode(names) else {
            return StatCard(id: "whiteWhale", title: String(localized: "YOUR WHITE WHALE"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 10, repsSoFar: 0)
        }
        return StatCard(
            id: "whiteWhale", title: String(localized: "YOUR WHITE WHALE"), value: top.value,
            context: String(localized: "missed \(Fmt.plain(top.count))×"),
            flavor: String(localized: "You just can't quit \(top.value). Time to make peace."),
            kind: .fact, minReps: 10, repsSoFar: names.count)
    }

    private static func nemesisCategoryCard(_ rows: [GameResult]) -> StatCard {
        let headers = rows.flatMap { $0.details.missedCellHeaders ?? [] }
        guard let top = mode(headers) else {
            return StatCard(id: "nemesisCategory", title: String(localized: "NEMESIS CATEGORY"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 5, repsSoFar: 0)
        }
        return StatCard(
            id: "nemesisCategory", title: String(localized: "NEMESIS CATEGORY"), value: top.value,
            context: String(localized: "\(Fmt.plain(top.count)) misses"), flavor: nil,
            kind: .fact, minReps: 5, repsSoFar: headers.count)
    }

    private static func rideOrDieCard(_ rows: [GameResult]) -> StatCard {
        let names = rows.flatMap { $0.details.draftedPlayerNames ?? [] }
        guard let top = mode(names) else {
            return StatCard(id: "rideOrDie", title: String(localized: "RIDE OR DIE"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 5, repsSoFar: 0)
        }
        return StatCard(
            id: "rideOrDie", title: String(localized: "RIDE OR DIE"), value: top.value,
            context: String(localized: "drafted \(Fmt.plain(top.count))×"),
            flavor: String(localized: "\(top.value) is basically on your payroll at this point."),
            kind: .fact, minReps: 5, repsSoFar: names.count)
    }

    /// The lowest-accuracy sport with at least 10 reps — always computed over the *unscoped*
    /// log (a nemesis is relative to other sports, meaningless once already pinned to one).
    private static func nemesisSportCard(_ rows: [GameResult]) -> StatCard {
        let bySport = Dictionary(grouping: rows, by: \.sport).mapValues(FormatSplit.init)
        let qualifying = bySport.filter { $0.value.attempted >= 10 }
        let worst = qualifying.sorted { a, b in
            let accA = a.value.accuracy ?? 1, accB = b.value.accuracy ?? 1
            return accA != accB ? accA < accB : a.key.rawValue < b.key.rawValue
        }.first
        let reps = rows.reduce(into: 0) { $0 += $1.attempted }
        guard let worst, let acc = worst.value.accuracy else {
            return StatCard(id: "nemesisSport", title: String(localized: "NEMESIS SPORT"), value: "—",
                            context: nil, flavor: nil, kind: .fact, minReps: 10, repsSoFar: reps)
        }
        return StatCard(
            id: "nemesisSport", title: String(localized: "NEMESIS SPORT"), value: worst.key.displayName,
            context: Fmt.percent(acc),
            flavor: String(localized: "\(worst.key.displayName) has your number. Time for a rematch."),
            kind: .fact, minReps: 10, repsSoFar: reps)
    }

    private static func cardsJudgedCard(_ rows: [GameResult]) -> StatCard {
        let total = rows.reduce(into: 0) { $0 += $1.attempted }
        return StatCard(
            id: "cardsJudged", title: String(localized: "CARDS JUDGED"), value: Fmt.grouped(total),
            context: nil, flavor: nil, kind: .number, minReps: 1, repsSoFar: total)
    }

    private static func timeOnClockCard(_ rows: [GameResult]) -> StatCard {
        let totalMs = rows.reduce(into: 0) { $0 += ($1.durationMs ?? 0) }
        let known = rows.filter { $0.durationMs != nil }.count
        return StatCard(
            id: "timeOnClock", title: String(localized: "TIME ON THE CLOCK"),
            value: totalMs > 0 ? Fmt.longDuration(ms: totalMs) : "—",
            context: nil, flavor: nil, kind: .duration, minReps: 1, repsSoFar: known)
    }

    // MARK: - Helpers

    /// The most frequent value in `values`, with a deterministic tie-break (first appearance
    /// order) so a fixture with two equally-common names doesn't pick a different one per run.
    private static func mode(_ values: [String]) -> (value: String, count: Int)? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        var firstIndex: [String: Int] = [:]
        for (i, v) in values.enumerated() {
            counts[v, default: 0] += 1
            if firstIndex[v] == nil { firstIndex[v] = i }
        }
        let best = counts.keys.sorted { a, b in
            counts[a]! != counts[b]! ? counts[a]! > counts[b]! : firstIndex[a]! < firstIndex[b]!
        }.first!
        return (best, counts[best]!)
    }

    private static func parsePercent(_ value: String) -> Double? {
        guard value.hasSuffix("%") else { return nil }
        return Double(value.dropLast()).map { $0 / 100 }
    }
}

/// Player-facing format name — mirrors `GameFormat.all`'s names (Home's format grid), the one
/// other place these get spelled out for a user rather than switched over internally.
private extension GameFormatKind {
    var displayName: String {
        switch self {
        case .keep4Normal: return "K4C4"
        case .keep4Hard:   return "K4C4 Hard"
        case .whoAmI:      return "Who Am I?"
        case .overUnder:   return "Over/Under"
        case .draftSpin:   return "Draft & Spin"
        case .grid:        return "The Grid"
        case .journeyman:  return "Journeyman"
        }
    }
}

/// Numeric-to-string formatting, kept in one place so grouping is applied deliberately rather
/// than by accident — `Text("\(someInt)")` applies locale thousands-grouping, but a `String`
/// built by interpolating a raw `Int` does not, and the two silently disagreeing (a year that
/// gained commas, a card count that didn't) is exactly the trap the callers here are avoiding.
private enum Fmt {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    /// Grouped for values a user thinks of as a big tally ("4,128 cards judged").
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? plain(value)
    }

    /// Ungrouped for values that should never carry a thousands separator (a year, a delta, a
    /// small count read as a single token).
    static func plain(_ value: Int) -> String { String(value) }

    /// "1h 42m" over an hour, "42m" under — for career-scale totals.
    static func longDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 { return "\(plain(hours))h \(plain(minutes))m" }
        return "\(plain(minutes))m"
    }

    /// "0:38" (m:ss) — for a single session's duration.
    static func shortDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
