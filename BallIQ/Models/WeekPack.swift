import Foundation

/// A batch of boards about the week a league just finished, dropped together
/// (`tools/ingest/pack.py`, tables `packs` + `pack_items`).
///
/// Board zero is always the sport's keep4 daily for the pack's release day, under the same
/// puzzle id, so one play counts on both surfaces. Every other board is unranked (`PlayMode.pack`):
/// the pack is a bonus, never an obligation.
struct WeekPack: Identifiable, Equatable {
    let id: String
    let sport: Sport
    /// "2026 Week 1".
    let label: String
    /// The device-local day the pack opens, `yyyy-MM-dd` (same convention as `active_date`).
    let releaseDate: String
    let items: [WeekPackItem]

    /// How long a pack stays on Home. A league week is seven days, so the next one lands as this
    /// one leaves; a sport that skips a week (bye, international break) simply has no card.
    static let daysCurrent = 7

    /// "2026 Week 1" -> "Week 1". The year is noise on a card about last week.
    var shortLabel: String {
        guard let space = label.firstIndex(of: " "), Int(label[..<space]) != nil else { return label }
        return String(label[label.index(after: space)...])
    }

    /// The daily card's badge for board zero: "WEEK 1 PACK".
    var badgeText: String { String(localized: "\(shortLabel.uppercased()) PACK") }

    /// Board zero is the day's daily only ON its release day. Played later it is an ordinary
    /// pack board, because by then it is no longer anyone's daily.
    func isDaily(_ item: WeekPackItem, today: String) -> Bool {
        item.ordinal == items.first?.ordinal && releaseDate == today
    }
}

struct WeekPackItem: Identifiable, Equatable {
    let id: String
    let ordinal: Int
    let role: Role
    let board: Board

    enum Board: Equatable {
        case keep4(Keep4Puzzle)
    }

    /// Why this board is in the pack. Unknown roles decode as `.other` rather than failing, so
    /// the builder can add a slot without a client release.
    enum Role: String {
        case headline, game, position, division, niche, other

        var label: String {
            switch self {
            case .headline: return String(localized: "HEADLINE")
            case .game:     return String(localized: "GAME OF THE WEEK")
            case .position: return String(localized: "POSITION")
            case .division: return String(localized: "DIVISION")
            case .niche:    return String(localized: "DEEP CUT")
            case .other:    return String(localized: "BONUS")
            }
        }
    }

    var keep4: Keep4Puzzle {
        switch board { case .keep4(let puzzle): return puzzle }
    }

    /// The board's title without the pack's own label. Inside "Week 1 Pack", "2026 Week 1: top
    /// TE performances" says the week twice; the game board's title never carried it.
    func displayTitle(packLabel: String) -> String {
        let prefix = "\(packLabel): "
        let theme = keep4.theme
        guard theme.hasPrefix(prefix) else { return theme }
        let rest = theme.dropFirst(prefix.count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}

/// Whether the player has opened a pack yet. Home promotes an unopened pack to the top of the
/// page and settles it below the dailies once opened. Per device (UserDefaults): a signal about
/// what this screen has already shown, not account state worth syncing.
enum WeekPackEngagement {
    private static let key = "weekPackEngaged"
    /// Enough to cover every sport's current pack with room to spare; older ids age out.
    private static let limit = 40

    static func engaged(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func markEngaged(_ packID: String, defaults: UserDefaults = .standard) {
        var ids = defaults.stringArray(forKey: key) ?? []
        guard !ids.contains(packID) else { return }
        ids.append(packID)
        defaults.set(Array(ids.suffix(limit)), forKey: key)
    }
}

// MARK: - Wire rows

/// `packs` row. Plain `JSONDecoder` with explicit keys (see the `supabase-decode-gotcha`
/// memory: explicit snake keys through `.supabase` silently decode as `[]`).
struct WeekPackRow: Decodable, Equatable {
    let id: String
    let sport: Sport
    let label: String
    let releaseDate: String

    enum CodingKeys: String, CodingKey {
        case id, sport, label
        case releaseDate = "release_date"
    }
}

/// `pack_items` row, decoded one at a time. A row this build can't read (a format added later,
/// a malformed board) becomes `nil` and is skipped, instead of throwing inside an array decode
/// and taking every other board in the pack down with it, which is what an unknown value did
/// to the archive and to the Versus tab.
struct WeekPackItemRow: Decodable {
    let packID: String
    let item: WeekPackItem?

    enum CodingKeys: String, CodingKey {
        case id, ordinal, role, format, content
        case packID = "pack_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packID = try c.decode(String.self, forKey: .packID)
        let id = try c.decode(String.self, forKey: .id)
        let ordinal = try c.decode(Int.self, forKey: .ordinal)
        let role = WeekPackItem.Role(rawValue: (try? c.decode(String.self, forKey: .role)) ?? "") ?? .other
        let format = (try? c.decode(String.self, forKey: .format)) ?? ""
        switch format {
        case PuzzleFormat.keep4.rawValue:
            if let puzzle = try? c.decode(Keep4Puzzle.self, forKey: .content), puzzle.players.count == 8 {
                item = WeekPackItem(id: id, ordinal: ordinal, role: role, board: .keep4(puzzle))
            } else {
                item = nil
            }
        default:
            item = nil
        }
    }
}

/// Lossy array element: a row that fails even the envelope decode is dropped, not fatal.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Pure logic

enum WeekPackSchedule {
    /// The one pack per sport that Home should show on `today`: the latest released pack whose
    /// week-long window still covers today. Empty packs (every board unreadable) never show.
    static func current(_ packs: [WeekPack], today: String) -> [WeekPack] {
        var latest: [Sport: WeekPack] = [:]
        for pack in packs where !pack.items.isEmpty && isCurrent(pack, today: today) {
            if let existing = latest[pack.sport], existing.releaseDate >= pack.releaseDate { continue }
            latest[pack.sport] = pack
        }
        return Sport.allCases.compactMap { latest[$0] }
    }

    static func isCurrent(_ pack: WeekPack, today: String) -> Bool {
        guard pack.releaseDate <= today else { return false }
        return pack.releaseDate > windowStart(today: today)
    }

    /// The `release_date` a pack must be AFTER to still be current on `today`.
    static func windowStart(today: String) -> String {
        guard let date = parse(today),
              let start = gregorian.date(byAdding: .day, value: -WeekPack.daysCurrent, to: date) else {
            return today
        }
        return format(start)
    }

    /// Join `packs` rows with their items, items in board order.
    static func assemble(packs: [WeekPackRow], items: [WeekPackItemRow]) -> [WeekPack] {
        let byPack = Dictionary(grouping: items.compactMap { row in row.item.map { (row.packID, $0) } },
                                by: \.0)
        return packs.map { row in
            WeekPack(id: row.id, sport: row.sport, label: row.label, releaseDate: row.releaseDate,
                     items: (byPack[row.id] ?? []).map(\.1).sorted { $0.ordinal < $1.ordinal })
        }
    }

    private static let gregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = gregorian
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = gregorian.timeZone
        return f
    }

    private static func parse(_ day: String) -> Date? { formatter().date(from: day) }
    private static func format(_ date: Date) -> String { formatter().string(from: date) }
}

/// A player's progress through one pack, read off the career log.
struct WeekPackProgress: Equatable {
    /// Correct cards per board id, for boards that have a result.
    let correctByItem: [String: Int]

    init(pack: WeekPack, results: [GameResult]) {
        let ids = Set(pack.items.map(\.id))
        var best: [String: Int] = [:]
        for r in results where ids.contains(r.puzzleID) {
            best[r.puzzleID] = max(best[r.puzzleID] ?? 0, r.correct)
        }
        correctByItem = best
    }

    func played(_ item: WeekPackItem) -> Bool { correctByItem[item.id] != nil }
    func playedCount(in pack: WeekPack) -> Int { pack.items.filter(played).count }
    func isComplete(_ pack: WeekPack) -> Bool { playedCount(in: pack) == pack.items.count }
    func totalCorrect(in pack: WeekPack) -> Int { pack.items.compactMap { correctByItem[$0.id] }.reduce(0, +) }

    /// Spoiler-free recap: one line of eight marks per board, correct first. Order within a line
    /// is deliberately not board order, which would give away which cards were keeps.
    func shareText(for pack: WeekPack) -> String {
        let board = pack.items.map { item -> String in
            let hits = correctByItem[item.id] ?? 0
            return ShareMessage.emojiRow(Array(repeating: true, count: hits)
                                         + Array(repeating: false, count: max(0, 8 - hits)),
                                         perLine: 0)
        }.joined(separator: "\n")
        let headline = String(localized: "\(pack.sport.displayName) \(pack.label) Pack on BallIQ")
        let detail = String(localized: "\(totalCorrect(in: pack))/\(pack.items.count * 8) cards")
        return ShareMessage.compose(headline: headline, board: board, detail: detail,
                                    campaign: "week_pack")
    }
}
