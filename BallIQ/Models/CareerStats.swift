import Foundation

/// Headline totals across a player's entire recorded history — the numbers atop the stats
/// screen (games played, distinct days, cards judged, career accuracy) plus per-sport and
/// per-format splits. Pure aggregation over `GameResult`; nothing here reads or writes disk.
struct CareerSummary: Equatable {
    let games: Int
    let days: Int
    let cardsJudged: Int
    let perfects: Int
    let accuracy: Double?
    let totalPlayMs: Int
    let firstPlayed: Date?
    let bySport: [Sport: FormatSplit]
    let byFormat: [GameFormatKind: FormatSplit]

    init(_ rows: [GameResult]) {
        games = rows.count
        days = CareerStatsMath.distinctDayCount(rows.map(\.playedAt))
        cardsJudged = rows.reduce(into: 0) { $0 += $1.attempted }
        perfects = rows.filter(\.perfect).count
        let correctSum = rows.reduce(into: 0) { $0 += $1.correct }
        accuracy = cardsJudged > 0 ? Double(correctSum) / Double(cardsJudged) : nil
        totalPlayMs = rows.reduce(into: 0) { $0 += ($1.durationMs ?? 0) }
        firstPlayed = rows.map(\.playedAt).min()
        bySport = Dictionary(grouping: rows, by: \.sport).mapValues(FormatSplit.init)
        byFormat = Dictionary(grouping: rows, by: \.format).mapValues(FormatSplit.init)
    }
}

/// One slice (a sport, a format) of `CareerSummary` — same shape either way, so `bySport` and
/// `byFormat` can share it instead of two near-identical structs.
struct FormatSplit: Equatable {
    let games: Int
    let correct: Int
    let attempted: Int
    /// The best raw `score` this slice ever posted, or nil if nothing here qualifies. Filters
    /// on `countsForRecords` and `maxScore > 0` — a re-rollable practice board or an open-ended
    /// format's score isn't a "best" in any meaningful sense.
    let bestScore: Int?
    let perfects: Int

    var accuracy: Double? { attempted > 0 ? Double(correct) / Double(attempted) : nil }

    init(_ rows: [GameResult]) {
        games = rows.count
        correct = rows.reduce(into: 0) { $0 += $1.correct }
        attempted = rows.reduce(into: 0) { $0 += $1.attempted }
        perfects = rows.filter(\.perfect).count
        bestScore = rows
            .filter { $0.mode.countsForRecords && $0.maxScore > 0 }
            .map(\.score)
            .max()
    }
}

/// Pure math shared by `CareerSummary` and `StatCatalog` — streaks, runs, and time-bucketing
/// that don't belong to either type specifically. Everything here takes plain arrays/closures
/// so each piece is testable on its own without assembling a full fixture set per case.
enum CareerStatsMath {

    /// Distinct local calendar days represented in `dates`.
    static func distinctDayCount(_ dates: [Date], calendar: Calendar = .current) -> Int {
        Set(dates.map { calendar.startOfDay(for: $0) }).count
    }

    /// Longest run of *consecutive* calendar days appearing anywhere in `dates`. A gap of more
    /// than one day breaks the streak; multiple sessions on the same day don't extend it twice.
    /// Walks `Calendar.date(byAdding:)` day-by-day rather than subtracting `TimeInterval`s, so a
    /// DST transition (a 23- or 25-hour "day") still counts as exactly one calendar day.
    static func longestDailyStreak(_ dates: [Date], calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
        guard !days.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<days.count {
            if let expected = calendar.date(byAdding: .day, value: 1, to: days[i - 1]),
               calendar.isDate(expected, inSameDayAs: days[i]) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }

    /// Longest run of consecutive-in-time rows for which `predicate` holds — e.g. the longest
    /// streak of perfect games, across all formats or pre-filtered to one. Sorts defensively
    /// rather than trusting caller order: a filtered subset of an already-chronological array
    /// is still chronological, but a caller shouldn't have to know that to use this safely.
    static func longestRun(_ rows: [GameResult], where predicate: (GameResult) -> Bool) -> Int {
        let ordered = rows.sorted { $0.playedAt < $1.playedAt }
        var longest = 0
        var current = 0
        for row in ordered {
            if predicate(row) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// A 0...1 steadiness score ("Metronome Score") over the most recent `lastN` *ranked* rows:
    /// 1 means every one of those sessions performed about the same, 0 means wild swings.
    /// `performance` (not `accuracy`) is the input because it's the one quality signal every
    /// format agrees on, including the ones with no accuracy concept. Needs at least 3 rows to
    /// mean anything — nil below that rather than reporting a misleadingly perfect score off one
    /// or two data points.
    static func consistencyScore(_ rows: [GameResult], lastN: Int = 20) -> Double? {
        let recent = rows.filter(\.ranked)
            .sorted { $0.playedAt < $1.playedAt }
            .suffix(lastN)
        guard recent.count >= 3 else { return nil }
        let values = recent.map(\.performance)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let stddev = variance.squareRoot()
        // `performance` lives in 0...1, so a stddev of 0.5 (the max spread a run of alternating
        // 0s and 1s can produce) is already "totally inconsistent" — scale so that maps to 0
        // instead of a middling 0.5.
        return max(0, 1 - stddev * 2)
    }

    /// Accuracy split keyed by weekday (`Calendar.component(.weekday, ...)`: 1 = Sunday).
    static func accuracyByDayOfWeek(_ rows: [GameResult], calendar: Calendar = .current) -> [Int: FormatSplit] {
        Dictionary(grouping: rows) { calendar.component(.weekday, from: $0.playedAt) }
            .mapValues(FormatSplit.init)
    }

    /// Accuracy split keyed by coarse time-of-day bucket.
    static func accuracyByTimeOfDay(_ rows: [GameResult], calendar: Calendar = .current) -> [TimeOfDayBucket: FormatSplit] {
        Dictionary(grouping: rows) { TimeOfDayBucket(hour: calendar.component(.hour, from: $0.playedAt)) }
            .mapValues(FormatSplit.init)
    }
}

/// Coarse "when do you play" buckets — hour ranges chosen to read naturally in a sentence
/// ("you're a Night Owl") rather than clock precision.
enum TimeOfDayBucket: String, CaseIterable, Hashable {
    case earlyMorning
    case midday
    case afternoon
    case evening
    case lateNight

    init(hour: Int) {
        switch hour {
        case 5..<9:   self = .earlyMorning
        case 9..<14:  self = .midday
        case 14..<18: self = .afternoon
        case 18..<22: self = .evening
        default:      self = .lateNight   // wraps 22:00...4:59
        }
    }

    var label: String {
        switch self {
        case .earlyMorning: return String(localized: "Early Riser")
        case .midday:        return String(localized: "Midday")
        case .afternoon:     return String(localized: "Afternoon")
        case .evening:        return String(localized: "Evening")
        case .lateNight:     return String(localized: "Night Owl")
        }
    }
}
