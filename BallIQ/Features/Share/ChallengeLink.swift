import Foundation

/// A finished result compressed into something a stranger can act on: which board was played,
/// what there is to beat, and who set it.
///
/// The link deliberately carries **no puzzle content** — only the board's *identity*. Every
/// daily format is already canonical per `(sport, calendar day)` (see
/// `RemotePuzzleRepository.pick`), so "the recipient plays the same board" is a server
/// guarantee, not something the link has to transport. That keeps the URL short enough to survive a group chat unmangled, and means a
/// challenge can never hand someone a board that disagrees with the one the app would serve.
///
/// Two links come out of one challenge, because iOS gives no way to have a single one do both
/// jobs without Universal Links (which need a hosted `apple-app-site-association` *and* an
/// `associated-domains` entitlement — see `docs/MARKETING.md` and the note on `storeURL`):
///   - `url` (`balliq://challenge?…`) opens the app straight into the board. Useless to anyone
///     who hasn't installed it — tapping does nothing at all.
///   - `storeURL` (App Store, carrying a campaign token) works for everyone but can't carry the
///     recipient into the board.
/// `shareText` posts the second one, because the whole point is reaching people who don't have
/// the app yet. The first is what a redirect page (or a future Universal Link) hands off to.
struct ChallengeLink: Equatable, Identifiable {

    /// The link itself is the identity — `fullScreenCover(item:)` re-presents when it changes,
    /// which is exactly the behaviour wanted if a second challenge arrives while one is open.
    var id: String { url.absoluteString }


    /// The link addresses the same set of stable-board formats every other duel surface does —
    /// `PuzzleFormat`'s own doc comment is the canonical explanation of why Over/Under and
    /// Draft & Spin are excluded (a seeded RNG drawn *over a sampled player pool*, so two
    /// devices on the same day can legitimately be dealt different cards — there is no "same
    /// board" to challenge anyone to). Was its own `{grid, keep4}` enum before `PuzzleFormat`
    /// existed; kept as a typealias so every existing `ChallengeLink.Format.*` call site here
    /// and in the result views still reads naturally.
    typealias Format = PuzzleFormat

    let format: Format
    let sport: Sport
    /// `yyyy-MM-dd` — the board's identity, same string the ingest pipeline stamps
    /// `active_date` with (the challenger's local day via `PuzzleStore.localDayString`; a
    /// recipient in another timezone still resolves this exact date, not their own "today").
    let day: String
    /// The score to beat in the format's own natural unit: cells solved out of 9 for the Grid,
    /// correct picks out of 8 for Keep 4, clue efficiency out of 6 for Who Am I? (see
    /// `ChallengeLink.whoAmIHits(_:)` — the one place that conversion is made). Carried as a
    /// pair rather than a fraction so the head-to-head line can render "7/9" without knowing
    /// the format's board size.
    let hits: Int
    let outOf: Int
    /// Points, used only to break a tie on `hits`.
    let score: Int
    /// The challenger's display name, when there is one. Optional because a signed-out player
    /// has no username and "someone" still makes a perfectly good challenge.
    let challenger: String?

    init(format: Format, sport: Sport, day: String, hits: Int, outOf: Int,
         score: Int, challenger: String? = nil) {
        self.format = format
        self.sport = sport
        self.day = day
        self.hits = hits
        self.outOf = outOf
        self.score = score
        // An empty username is the same thing as no username; normalise here so every call
        // site downstream can just check for nil.
        self.challenger = (challenger?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - The app link

    static let scheme = "balliq"
    static let host = "challenge"

    /// Single-letter keys: the whole string ends up visible in a chat bubble on the redirect
    /// path, and every character spent on `format=` is one not spent on the emoji grid.
    private enum Key {
        static let format = "f", sport = "s", day = "d"
        static let hits = "h", outOf = "o", score = "p", name = "n"
    }

    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = Self.host
        var items = [
            URLQueryItem(name: Key.format, value: format.rawValue),
            URLQueryItem(name: Key.sport, value: sport.rawValue),
            URLQueryItem(name: Key.day, value: day),
            URLQueryItem(name: Key.hits, value: String(hits)),
            URLQueryItem(name: Key.outOf, value: String(outOf)),
            URLQueryItem(name: Key.score, value: String(score)),
        ]
        if let challenger { items.append(URLQueryItem(name: Key.name, value: challenger)) }
        c.queryItems = items
        // Every component is either a fixed literal or percent-encoded by URLComponents, so
        // this cannot fail; the fallback keeps the type non-optional for call sites.
        return c.url ?? URL(string: "\(Self.scheme)://\(Self.host)")!
    }

    /// Parses a `balliq://challenge?…` URL. Returns nil for anything else — including
    /// `balliq://play/<id>`, which is the *other*, pre-existing deep link (see `ContentView`).
    ///
    /// A missing or malformed number is a rejection rather than a defaulted zero: a challenge
    /// that silently claims the challenger scored 0 would tell the recipient they'd won before
    /// they played.
    static func parse(_ url: URL) -> ChallengeLink? {
        guard url.scheme == scheme, url.host == host,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.queryItems else { return nil }
        let byKey = Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })

        guard let format = byKey[Key.format].flatMap(Format.init(rawValue:)),
              let sport = byKey[Key.sport].flatMap(Sport.init(rawValue:)),
              let day = byKey[Key.day], isDayString(day),
              let hits = byKey[Key.hits].flatMap(Int.init),
              let outOf = byKey[Key.outOf].flatMap(Int.init),
              let score = byKey[Key.score].flatMap(Int.init),
              outOf > 0, (0...outOf).contains(hits) else { return nil }

        return ChallengeLink(format: format, sport: sport, day: day, hits: hits,
                             outOf: outOf, score: score, challenger: byKey[Key.name])
    }

    /// `yyyy-MM-dd` shape check. The day goes straight into a PostgREST `active_date` filter, so
    /// it is validated at the trust boundary rather than trusted because it arrived in a URL.
    static func isDayString(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(dayOfMonth) else { return false }
        return true
    }

    // MARK: - The public link

    /// The live App Store listing. Already used bare by the Grid share text since 1.2.
    static let appStoreID = ShareMessage.appStoreID

    /// App Analytics campaign token — `chal_grid_nfl`, so the report splits by format and sport
    /// and nothing finer. See `ShareMessage.storeURL` for the `pt` attribution caveat.
    var campaignToken: String { "chal_\(format.rawValue)_\(sport.rawValue)" }

    var storeURL: URL { ShareMessage.storeURL(campaign: campaignToken) }

    // MARK: - The message

    /// Noon *local* on the board's day. Noon rather than midnight, and local rather than UTC,
    /// so that the reformat that resolves the board (`PuzzleStore.localDayString`, local-zone)
    /// lands back on this same calendar day instead of slipping one either side — noon UTC
    /// would read as tomorrow in UTC+13/+14 and hand the recipient the wrong board.
    var date: Date? {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = .current
        parser.locale = Locale(identifier: "en_US_POSIX")
        return parser.date(from: "\(day) 12:00")
    }

    /// "Jul 27" — the board's day in the reader's own locale. Falls back to the raw string if
    /// it somehow isn't parseable (it always is; `parse` validates the shape).
    var displayDay: String {
        guard let date else { return day }
        let out = DateFormatter()
        out.timeZone = .current
        out.setLocalizedDateFormatFromTemplate("MMMd")
        return out.string(from: date)
    }

    /// "I went 7/9 on today's NFL Grid — beat that." The line a stranger reads first, so it has
    /// to say the sport, the format, and the number, and it has to end in a dare.
    ///
    /// `format.shareName`, not `displayName`: the tile name "The Grid" carries its own article,
    /// and this sentence supplies one of its own ("today's"). See `PuzzleFormat.shareName`.
    func headline(now: Date = Date()) -> String {
        let when = day == PuzzleStore.localDayString(now) ? "today's" : "the \(displayDay)"
        return "I went \(hits)/\(outOf) on \(when) \(sport.displayName) \(format.shareName) — beat that."
    }

    /// The full share payload: headline, the spoiler-free board picture, the score, the link.
    ///
    /// `board` is the format's own visual — the Grid's 🟩⬛ emoji grid, Keep 4's ✅❌ strip. It is
    /// passed in rather than built here because only the caller knows the board's shape, and
    /// keeping it a plain string is what lets both formats share one message template.
    ///
    /// Order is deliberate and matches what actually spreads (Wordle, Immaculate Grid): the
    /// picture is the middle of the message, never the end, so it survives a chat client's
    /// "…more" truncation with the link still visible.
    func shareText(board: String? = nil, now: Date = Date()) -> String {
        ShareMessage.compose(headline: headline(now: now), board: board,
                             detail: scoreLine, campaign: campaignToken)
    }

    /// "7/9 · 1,240 pts" — grouped thousands, because an ungrouped `1240` reads as a year.
    var scoreLine: String { "\(hits)/\(outOf) · \(ShareMessage.points(score)) pts" }

    // MARK: - Head to head

    enum Outcome: Equatable {
        case win, loss, tie

        /// The result banner's verdict, from the recipient's point of view.
        var verdict: String {
            switch self {
            case .win:  return "YOU WIN"
            case .loss: return "YOU LOST"
            case .tie:  return "DEAD HEAT"
            }
        }
    }

    /// Compares the recipient's run against the challenger's. `hits` decides it; points only
    /// break a tie, so a 7/9 always beats a 6/9 however many points the 6/9 racked up.
    func outcome(hits theirHits: Int, score theirScore: Int) -> Outcome {
        if theirHits != hits { return theirHits > hits ? .win : .loss }
        if theirScore != score { return theirScore > score ? .win : .loss }
        return .tie
    }

    /// "Alex went 7/9" — the challenger's line on the head-to-head banner.
    var challengerLine: String {
        "\(challenger ?? "They") went \(hits)/\(outOf)"
    }

    // MARK: - Who Am I?'s hits/outOf conversion

    /// Who Am I? has no natural "N correct out of M" — one guess is either right or wrong. Its
    /// challengeable unit is **clue efficiency**: a first-clue solve is worth the most (matching
    /// `WhoAmIScoring`'s own points curve) so it reads as `outOf`/`outOf`, and a give-up reads as
    /// `0`/`outOf` — `outcome(hits:score:)`'s existing "hits decide it, points break the tie"
    /// logic then works completely unchanged.
    ///
    /// The one place this mapping is made, called from both the share path
    /// (`WhoAmIResultView.shareText`) and the accepted side (`ChallengeResultBanner` via
    /// `WhoAmIResultView`), so the two can't independently drift on what "hits" means here.
    static func whoAmIHits(_ result: WhoAmIScoring.Result) -> Int {
        result.solved ? WhoAmIScoring.perClue.count + 1 - result.cluesUsed : 0
    }

    /// The denominator matching `whoAmIHits(_:)` — the number of clues a Who Am I? puzzle carries.
    static let whoAmIOutOf = WhoAmIScoring.perClue.count

    /// Journeyman's equivalent: guesses *not* needed, plus one, so naming the player first time
    /// scores the full five and an unsolved run scores nothing.
    static func journeymanHits(_ result: JourneymanScoring.Result) -> Int {
        result.solved ? JourneymanScoring.maxGuesses + 1 - result.guessesUsed : 0
    }

    /// The denominator matching `journeymanHits(_:)` — the format's guess limit.
    static let journeymanOutOf = JourneymanScoring.maxGuesses
}
