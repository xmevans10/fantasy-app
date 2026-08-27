import SwiftUI

/// Puzzle Blitz — a fixed-length run that serves **whole, real puzzles** back to back, drawn at
/// random from the formats and sports the player picked on setup, with the score withheld until
/// the clock stops.
///
/// **The clock is a session bound, not a per-puzzle deadline, and that distinction is the whole
/// reason this mode is allowed to have one at all.** M25 (`SpeedMultiplier`) removed every timer
/// in the app because a countdown that could force-finish a board made the clock a fail-state —
/// "a player who knew the answer but read slowly lost to the timer rather than to an opponent",
/// which is BALLIQ_SPEC §1 theme 5 inverted. Blitz does not reintroduce that: the clock decides
/// **whether another puzzle is served**, never how long you get on the one in front of you (see
/// `BlitzSession.acceptsNewRound`). Time expiring means "that was your last board", not "your
/// board is forfeit" — so a slow reader plays fewer puzzles, and never loses one they'd solved.
///
/// For the same reason there is **no `SpeedMultiplier` bonus on a blitz round**. Speed is already
/// paid for, once, by the only currency this mode has: finishing sooner leaves room for another
/// puzzle. Layering the M25 gradient on top would price the same second twice.
enum BlitzFormat: String, Codable, CaseIterable, Identifiable, Hashable {
    case keep4, whoami, journeyman, overunder

    var id: String { rawValue }

    /// The `puzzles`-row format this draws boards from — **nil for Over/Under**, whose rounds are
    /// generated on-device from a sampled catalog pool and have no stable row anywhere. That is
    /// the same absence `PuzzleFormat`'s own doc comment explains, and the reason this enum
    /// exists beside it rather than instead of it: Blitz's domain is "formats that can be one
    /// round", which includes Over/Under and (see `BlitzFormat.excluded`) excludes The Grid.
    var puzzleFormat: PuzzleFormat? {
        switch self {
        case .keep4:      return .keep4
        case .whoami:     return .whoami
        case .journeyman: return .journeyman
        case .overunder:  return nil
        }
    }

    /// The rating/XP weight class a round of this plays at. Only ever used to tag the round's own
    /// tally — a blitz run is unranked end to end (see `BlitzScoring`), so no rating math reads it.
    var kind: GameFormatKind {
        switch self {
        case .keep4:      return .keep4Normal
        case .whoami:     return .whoAmI
        case .journeyman: return .journeyman
        case .overunder:  return .overUnder
        }
    }

    /// Player-facing name/symbol/colors, single-sourced from `PuzzleFormat` and `GameFormat.all`
    /// wherever those already say it, so a rename lands in one place (AGENTS.md §4). Over/Under
    /// carries its own literals only because it is in neither of those tables.
    var displayName: String { puzzleFormat?.displayName ?? String(localized: "Over / Under") }
    var symbol: String { puzzleFormat?.symbol ?? "arrow.up.arrow.down" }

    /// Matches each format's established cartridge color on Home (`GameFormat.all`).
    var tint: Color {
        switch self {
        case .keep4:      return .accentFill
        case .whoami:     return .voltFill
        case .journeyman: return .goldFill
        case .overunder:  return .dangerFill
        }
    }

    var onTint: Color {
        switch self {
        case .keep4:      return .onAccent
        case .whoami:     return .onVolt
        case .journeyman: return .onGold
        case .overunder:  return .onDanger
        }
    }

    /// How long one round of this format is *expected* to take, and therefore how much it is
    /// worth (see `BlitzScoring.points`).
    ///
    /// Three of the four are `SpeedMultiplier.par(for:)` verbatim rather than fresh numbers — the
    /// app already has one statement of "how long this format takes" and a second one would drift
    /// from it. Over/Under is the exception in both directions: `SpeedMultiplier` deliberately
    /// declines to give it a par (nothing there should reward tapping an arcade run faster), but
    /// Blitz *must* have one, because without it a single over/under call would pay the same as
    /// an eight-card sort and every rational player would blitz nothing else. 8s is a deliberate
    /// blitz-local estimate of one read-and-swipe, documented here as the number to revisit if
    /// the per-format mix ever looks lopsided in real runs.
    var parSeconds: TimeInterval {
        switch self {
        case .keep4:      return SpeedMultiplier.par(for: PuzzleFormat.keep4)
        case .whoami:     return SpeedMultiplier.par(for: PuzzleFormat.whoami)
        case .journeyman: return SpeedMultiplier.par(for: PuzzleFormat.journeyman)
        case .overunder:  return 8
        }
    }

    /// The `performance` a player who knows nothing would average, which blitz subtracts before
    /// paying anything out (see `BlitzScoring.quality`).
    ///
    /// Keep4 and Over/Under both have a real chance floor and it is roughly a half: an over/under
    /// call is a coin flip, and a blind 4/4 sort of eight cards expects four right by assignment
    /// alone. (Keep4's true floor is messier than 0.5 — the forced-pile rule means even a
    /// deliberately bad sorter scores well above zero — but 0.5 is the honest expectation for a
    /// uniform random split and is the number worth paying from.) Who Am I? and Journeyman have
    /// no floor at all: an unsolved board scores exactly 0, and nobody guesses a name by luck.
    ///
    /// Without this subtraction a blitz of pure Over/Under would bank half of every round's value
    /// for free, at the shortest par in the mode — the exact shape of outcome BALLIQ_SPEC §1
    /// theme 5 forbids, where something other than knowing ball decides the score.
    var chanceFloor: Double {
        switch self {
        case .keep4, .overunder:  return 0.5
        case .whoami, .journeyman: return 0
        }
    }

    /// Whether this format can serve a board for `sport` **at all**, as a matter of category
    /// rather than of stock.
    ///
    /// Only Journeyman is ever false, and only for tennis — see `Sport.hasClubCareers`. Every
    /// other pairing either has content or is a backfill away from having it, which is a
    /// different situation and is handled by the loader simply drawing something else.
    func isAvailable(for sport: Sport) -> Bool {
        self != .journeyman || sport.hasClubCareers
    }

    /// Whether any of `sports` can serve this format. Drives the setup picker: a format no
    /// selected sport can produce is shown unavailable rather than silently never appearing.
    func isAvailable(forAny sports: Set<Sport>) -> Bool {
        sports.contains { isAvailable(for: $0) }
    }

    /// Formats that are deliberately **not** blitzable, and why — stated in code because the
    /// obvious next request is "why isn't The Grid in here".
    ///
    /// - **The Grid** is nine free-text answers against a 180s par. It is a whole session, not a
    ///   round: a single board would consume most of a 3-minute blitz and all of a 1-minute one,
    ///   so serving it would make the timer choice meaningless rather than adding a format.
    /// - **Draft & Spin** builds a roster over a sequence of spins. It has no right answer per
    ///   decision (`GameResult` records `attempted: 0` for it), so it can't contribute a
    ///   `performance` for blitz to pay on, and it isn't a puzzle in the sense this mode means.
    ///
    /// Both stay reachable from their own Home tiles exactly as before. This is the honest
    /// smaller version rather than a stretched one (AGENTS.md §5 / dev-taste §5).
    static let excluded = "grid, draftSpin"
}

/// How long a blitz run lasts. Fixed choices rather than a slider — the score is only comparable
/// against your own best at the *same* length, and three named lengths keep that legible.
enum BlitzDuration: Int, Codable, CaseIterable, Identifiable {
    case one = 60
    case three = 180
    case five = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var minutes: Int { rawValue / 60 }

    /// "1 MIN" / "3 MIN" / "5 MIN".
    var shortLabel: String { String(localized: "\(minutes) MIN") }
}

/// What the player picked on the setup screen. Persisted as the app default (BALLIQ_SPEC §1
/// theme 2: per-game configuration, and the last choice sticks).
struct BlitzConfig: Codable, Equatable {
    var sports: Set<Sport>
    var formats: Set<BlitzFormat>
    var duration: BlitzDuration

    /// NFL + every format, five minutes — the widest honest opening offer for a first run. NFL
    /// alone because it is the one sport no entitlement gates (`Entitlements.freeSports`), and a
    /// default that opens the paywall on Start is a bad first impression.
    static let `default` = BlitzConfig(sports: [.nfl], formats: Set(BlitzFormat.allCases),
                                       duration: .five)

    /// A run needs at least one sport and one format that sport can actually serve.
    var isPlayable: Bool { !sports.isEmpty && !servableFormats.isEmpty }

    /// Sports in `Sport.allCases` order — a `Set` has none, and every surface that lists the
    /// chosen sports (setup caption, result header) must list them the same way.
    var orderedSports: [Sport] { Sport.allCases.filter(sports.contains) }

    /// The ticked formats, in canonical order. **Includes formats the chosen sports can't
    /// actually serve** — this is the raw selection, which the setup picker renders. Everything
    /// that reasons about what a run will *contain* uses `servableFormats` instead.
    var orderedFormats: [BlitzFormat] { BlitzFormat.allCases.filter(formats.contains) }

    /// The ticked formats that at least one chosen sport can produce a board for.
    ///
    /// The distinction is load-bearing for exactly one pairing today (Journeyman + tennis, see
    /// `Sport.hasClubCareers`) and it was worth splitting because the naive version lies twice:
    /// a tennis blitz with all four ticked estimated four boards when Journeyman can never come
    /// up (the true mix is three formats and ~5 boards), and a tennis + Journeyman-only config
    /// sailed past Start into the empty state with no warning.
    var servableFormats: [BlitzFormat] {
        orderedFormats.filter { $0.isAvailable(forAny: sports) }
    }

    /// Roughly how many boards this mix fits in the chosen length, from the formats' own par
    /// times drawn uniformly (which is exactly how `BlitzRoundLoader.next` draws them).
    ///
    /// Shown on the setup screen because the honest consequence of "one board of every format" is
    /// non-obvious and unpleasant to discover mid-run: an all-formats five-minute blitz is about
    /// **five** boards, because a K4C4 board is fifteen Over/Unders long. Saying so up front turns
    /// that from a surprise into the reason to untick K4C4 — the player's dial rather than the
    /// loader's opinion (see `BlitzRoundLoader.next`). An estimate, never a promise: a player
    /// faster than par gets more, and the label says "about".
    var estimatedBoards: Int {
        let pars = servableFormats.map(\.parSeconds)
        guard !pars.isEmpty else { return 0 }
        let meanPar = pars.reduce(0, +) / Double(pars.count)
        guard meanPar > 0 else { return 0 }
        return max(1, Int((duration.seconds / meanPar).rounded()))
    }

    // MARK: Persistence

    private static let key = "blitz.config.v1"

    static func load(from defaults: UserDefaults = .standard) -> BlitzConfig {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(BlitzConfig.self, from: data),
              decoded.isPlayable else { return .default }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// One finished board inside a run. Deliberately carries the format's **own** `performance`
/// rather than a pre-scored number, so `BlitzScoring` stays a pure function of the run and the
/// whole ladder of points can be recomputed (and tested) without replaying any game view.
struct BlitzRoundResult: Equatable, Identifiable {
    let id = UUID()
    let format: BlitzFormat
    let sport: Sport
    let puzzleID: String
    /// 0...1, the format's own rating-engine input — the one quality measure every format in the
    /// app already agrees on (see `GameResult.performance`), and therefore the only sane basis
    /// for paying four different formats out of one purse.
    let performance: Double
    /// Whether this board counts as "got it": solved for the one-answer formats, better than the
    /// chance floor for the two that have one. Drives the combo and the end-of-run tally only.
    let cleared: Bool
    /// Wall-clock seconds this board took, for the end-of-run pace line.
    let elapsed: TimeInterval

    static func == (a: BlitzRoundResult, b: BlitzRoundResult) -> Bool { a.id == b.id }
}

/// A board that was on screen when the clock hit zero.
///
/// Carries only what the result screen needs to name it. There is no `performance` because the
/// player never finished it — that is the whole point of the type existing separately from
/// `BlitzRoundResult` rather than as a flag on it.
struct BlitzCutOff: Equatable {
    let format: BlitzFormat
    let sport: Sport
}

/// Pure scoring for a blitz run. Nothing here reads a clock or a repository, so every number the
/// result screen shows is reproducible from the round list alone.
///
/// **The invariant this type exists to hold: at par pace, every format pays the same points per
/// second.** A player who picks only Over/Under and one who picks only K4C4 are competing on how
/// well they know ball, not on which format they happened to tick. It is enforced by
/// `BlitzScoringTests.testEveryFormatPaysTheSameRateAtPar`, not merely true today.
enum BlitzScoring {
    /// Points a perfectly-played second of any format is worth. The single dial for the whole
    /// mode's headline number.
    static let pointsPerParSecond = 10.0

    /// Consecutive cleared boards add 10% each, capped at five. Small on purpose: a combo is
    /// juice (BALLIQ_SPEC §1 theme 3), and at ×1.5 maximum it can reorder two players who are
    /// close and cannot rescue one who isn't — the same ceiling `OverUnderScoring` picked for
    /// the same reason.
    static let comboStep = 0.1
    static let comboCap = 5

    static func comboMultiplier(consecutiveCleared: Int) -> Double {
        1.0 + Double(min(max(consecutiveCleared, 0), comboCap)) * comboStep
    }

    /// A round's `performance` rebased so that **chance is worth exactly zero**: `+1` for
    /// flawless, `0` for what a guesser would average, and *negative* for worse than that.
    ///
    /// **The negative half is not a punishment, it is the only way the floor can work on a
    /// one-decision board** — and it was put here by a failing test, which is worth recording.
    /// The first version clamped this at zero, which nets chance out fine on a format whose
    /// round-level `performance` is itself an average of many decisions (a Keep4 board's eight
    /// cards land near 0.5 when guessed, so a clamped rebase pays ~0). It does nothing at all on
    /// Over/Under, whose round `performance` is binary: rebasing 1 gives 1 and rebasing 0 gives
    /// 0, so a coin-flipper banked half the purse and an Over/Under-only blitz became the
    /// strictly correct way to play badly. Allowing the loss makes a wrong call cost what a right
    /// one pays, which is the only treatment of a coin flip that actually averages to nothing.
    ///
    /// Only a format with a floor can ever go negative. Who Am I? and Journeyman have none, so an
    /// unsolved board is worth zero, never less — nobody should lose points for not knowing a
    /// name they were never going to guess.
    static func surplus(_ performance: Double, format: BlitzFormat) -> Double {
        let floor = format.chanceFloor
        guard floor < 1 else { return 0 }
        return min(1, max(-1, (performance - floor) / (1 - floor)))
    }

    /// `surplus` with the loss half discarded — the 0...1 shape the career log's `performance`
    /// column is check-constrained to, and the only place a blitz round's quality is reported
    /// outside this type.
    static func quality(_ performance: Double, format: BlitzFormat) -> Double {
        max(0, surplus(performance, format: format))
    }

    /// The most one round of `format` can pay before any combo — its par length priced at
    /// `pointsPerParSecond`. K4C4 1200, Journeyman 1200, Who Am I? 900, Over/Under 80.
    static func maxRoundPoints(_ format: BlitzFormat) -> Int {
        Int((pointsPerParSecond * format.parSeconds).rounded())
    }

    /// What one round pays, given the combo it landed on. Negative when the board came in under
    /// chance — see `surplus`.
    ///
    /// **The combo multiplies gains only, never losses.** A streak is a reward for a run of good
    /// boards; letting it scale a bad one would mean the better you'd been playing, the more a
    /// single miss cost you, which is a punishment mechanic wearing a reward's clothes.
    static func points(_ round: BlitzRoundResult, consecutiveCleared: Int) -> Int {
        let value = surplus(round.performance, format: round.format)
        let base = pointsPerParSecond * round.format.parSeconds * value
        let combo = value > 0 ? comboMultiplier(consecutiveCleared: consecutiveCleared) : 1
        return Int((base * combo).rounded())
    }

    /// Every input that produced one round's points, kept together so the result screen can show
    /// the arithmetic instead of asserting a number.
    ///
    /// **Why this exists rather than the view recomputing it.** A round's points depend on the
    /// combo it landed on, which is a property of the *sequence* — so per-round points can only
    /// be obtained by folding the run front to back. A view that called `points(_:consecutiveCleared:)`
    /// per row would have to re-derive that fold and would get it wrong the first time someone
    /// filtered or re-sorted the list. `rows` is the same fold `rawTotal` performs, exposed once.
    struct RoundBreakdown: Equatable, Identifiable {
        let round: BlitzRoundResult
        /// Chance-rebased quality, `-1...1`. See `surplus`.
        let surplus: Double
        /// `pointsPerParSecond × parSeconds × surplus`, before any combo.
        let base: Double
        /// The multiplier this round actually received — `1` on a loss, since the combo
        /// multiplies gains only.
        let combo: Double
        /// How many cleared boards immediately preceded this one.
        let consecutiveCleared: Int
        let points: Int

        var id: UUID { round.id }
        /// The combo did something visible here — the only case worth drawing attention to.
        var comboApplied: Bool { combo > 1 }
    }

    /// The run folded in order, exposing each round's own arithmetic.
    ///
    /// `rows(_:).map(\.points).reduce(0,+) == rawTotal(_:)` by construction, and
    /// `BlitzScoringTests` locks it — the result screen's per-round list has to reconcile against
    /// the headline, and a breakdown that quietly disagreed with the total would be worse than no
    /// breakdown at all.
    static func rows(_ rounds: [BlitzRoundResult]) -> [RoundBreakdown] {
        var combo = 0
        var out: [RoundBreakdown] = []
        out.reserveCapacity(rounds.count)
        for round in rounds {
            let value = surplus(round.performance, format: round.format)
            let base = pointsPerParSecond * round.format.parSeconds * value
            let multiplier = value > 0 ? comboMultiplier(consecutiveCleared: combo) : 1
            out.append(RoundBreakdown(round: round, surplus: value, base: base,
                                      combo: multiplier, consecutiveCleared: combo,
                                      points: Int((base * multiplier).rounded())))
            combo = round.cleared ? combo + 1 : 0
        }
        return out
    }

    /// The run folded in order, **losses included** — the combo is a property of the *sequence*,
    /// so a run can only be scored front to back, never as a sum over an unordered set.
    ///
    /// Can be negative; `total` is what a player is shown. Both exist because the result screen's
    /// per-format breakdown has to reconcile against something, and a clamped headline would
    /// leave those rows summing to a different number than the one above them.
    static func rawTotal(_ rounds: [BlitzRoundResult]) -> Int {
        var combo = 0
        var total = 0
        for round in rounds {
            total += points(round, consecutiveCleared: combo)
            combo = round.cleared ? combo + 1 : 0
        }
        return total
    }

    /// The score a player sees: `rawTotal` with the floor at zero.
    ///
    /// Clamped because a negative blitz score says nothing a zero doesn't — "you were guessing" —
    /// and reads as a penalty for playing rather than as the honest bottom of the scale. The
    /// breakdown rows below it still show their real negative contributions, so the run stays
    /// legible; only the headline is floored.
    static func total(_ rounds: [BlitzRoundResult]) -> Int { max(0, rawTotal(rounds)) }

    /// The longest run of consecutive cleared boards — the one stat worth bragging about that
    /// isn't the score itself.
    static func bestStreak(_ rounds: [BlitzRoundResult]) -> Int {
        var best = 0, current = 0
        for round in rounds {
            current = round.cleared ? current + 1 : 0
            best = max(best, current)
        }
        return best
    }
}

/// Everything the end-of-run screen shows, computed once from the finished round list.
///
/// **This is the only place in a blitz where a score is ever produced**, and that is a product
/// requirement rather than an implementation detail: nothing mid-run may render a running total
/// (see `BlitzStatusBar`, which shows the clock and the board count and deliberately nothing
/// else). Keeping the arithmetic here — off the session object the boards can see — is what
/// makes that checkable by reading the code instead of by trusting it.
struct BlitzRunSummary: Equatable {
    let config: BlitzConfig
    let rounds: [BlitzRoundResult]
    let total: Int
    let cleared: Int
    let bestStreak: Int
    let elapsed: TimeInterval

    /// The unclamped sum the per-format breakdown reconciles against. See `BlitzScoring.total`.
    let rawTotal: Int

    /// Per-round arithmetic, in play order — what the result screen's expandable list renders.
    /// Folded once here rather than per row; see `BlitzScoring.RoundBreakdown`.
    let breakdown: [BlitzScoring.RoundBreakdown]

    /// The board the clock cut off, if it caught one mid-solve. Deliberately **not** a
    /// `BlitzRoundResult`: it has no `performance`, so scoring it would mean inventing one, and
    /// every honest choice there is wrong — a 0 would pay negative points on a format with a
    /// chance floor (punishing the player for the clock), and skipping it silently would leave
    /// the run's last board unaccounted for on a screen whose whole job is to account for them.
    /// It is shown, unscored, and excluded from every total.
    let cutOff: BlitzCutOff?

    init(config: BlitzConfig, rounds: [BlitzRoundResult], elapsed: TimeInterval,
         cutOff: BlitzCutOff? = nil) {
        self.config = config
        self.rounds = rounds
        self.cutOff = cutOff
        self.breakdown = BlitzScoring.rows(rounds)
        self.rawTotal = BlitzScoring.rawTotal(rounds)
        self.total = BlitzScoring.total(rounds)
        self.cleared = rounds.filter(\.cleared).count
        self.bestStreak = BlitzScoring.bestStreak(rounds)
        self.elapsed = elapsed
    }

    var played: Int { rounds.count }

    /// Rounds cleared over rounds played — nil on an empty run rather than 0%, the same
    /// distinction `GameResult.accuracy` makes and for the same reason: a run with no boards has
    /// no accuracy, it isn't 0% accurate.
    var accuracy: Double? { played > 0 ? Double(cleared) / Double(played) : nil }

    /// Points contributed per format, biggest first — the breakdown that answers "where did my
    /// score actually come from", which the score alone can't.
    var byFormat: [(format: BlitzFormat, played: Int, points: Int)] {
        var combo = 0
        var played: [BlitzFormat: Int] = [:]
        var points: [BlitzFormat: Int] = [:]
        for round in rounds {
            played[round.format, default: 0] += 1
            points[round.format, default: 0] += BlitzScoring.points(round, consecutiveCleared: combo)
            combo = round.cleared ? combo + 1 : 0
        }
        return played.keys
            .map { (format: $0, played: played[$0] ?? 0, points: points[$0] ?? 0) }
            .sorted { $0.points == $1.points ? $0.format.rawValue < $1.format.rawValue
                                             : $0.points > $1.points }
    }

    /// The run's `performance` for the career log — the mean round quality, which is already
    /// `0...1` and therefore satisfies `game_results.performance`'s check constraint. Zero on an
    /// empty run.
    var performance: Double {
        guard !rounds.isEmpty else { return 0 }
        let sum = rounds.reduce(0.0) { $0 + BlitzScoring.quality($1.performance, format: $1.format) }
        return min(1, max(0, sum / Double(rounds.count)))
    }

    /// The theoretical ceiling for the boards actually served — what a flawless run of this exact
    /// sequence would have paid. Not a ceiling on the *mode* (playing faster serves more boards),
    /// so the result screen reports it as "of what was on offer", never as a percentage of a run.
    var maxPossible: Int {
        var combo = 0
        var total = 0
        for round in rounds {
            total += Int((Double(BlitzScoring.maxRoundPoints(round.format))
                          * BlitzScoring.comboMultiplier(consecutiveCleared: combo)).rounded())
            combo += 1
        }
        return total
    }
}

/// How a board's remaining value is stated **inside a blitz**, where absolute points may not
/// appear on screen at all.
///
/// Who Am I? and Journeyman both headline the points a board is currently worth ("Worth 1,250
/// pts") and price the next clue or guess in points. Both numbers are wrong twice over in a
/// blitz: they are a score, shown mid-run, and they are not even the score this board will
/// actually pay — a blitz pays on par-normalized surplus (`BlitzScoring`), not on the format's
/// native curve. Restating the same information as a **share of this board's own maximum** keeps
/// the trade-off the formats are built around ("is one more clue worth it?") fully legible while
/// revealing nothing about the run.
///
/// It works for both formats without a special case because they share one scoring table by
/// design (`JourneymanScoring.perGuess` is deliberately `WhoAmIScoring.perClue`), so the
/// percentages come out as clean 20% steps in each.
enum BlitzBoardValue {
    /// "80% VALUE LEFT" — what solving right now would be worth, relative to a first-try solve.
    static func remaining(current: Int, max: Int) -> String {
        guard max > 0 else { return String(localized: "FULL VALUE") }
        return String(localized: "\(percent(current, of: max))% VALUE LEFT")
    }

    /// "Next clue · −20%".
    static func cost(_ cost: Int, of max: Int) -> String {
        guard max > 0, cost > 0 else { return "" }
        return "−\(percent(cost, of: max))%"
    }

    private static func percent(_ value: Int, of max: Int) -> Int {
        Int(((Double(value) / Double(max)) * 100).rounded())
    }
}

/// Per-duration personal bests, on device.
///
/// **Local only, and the ceiling is worth stating plainly**: `arcade_scores` — the weekly server
/// board Over/Under and The Grid post to — is keyed `(game, sport)` with a `check (game in
/// ('over_under','grid'))`, and a blitz run spans however many sports the player ticked. There is
/// no single sport to post it under, so blitz has no weekly board rather than a dishonest one
/// filed under whichever sport happened to come up first. A real board needs a sportless
/// `blitz_scores` table (and a duration column, since a 1-minute best and a 5-minute best are not
/// the same record) — deliberately deferred, not overlooked.
struct LocalBlitzStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ duration: BlitzDuration) -> String { "blitz.best.\(duration.rawValue)" }

    func highScore(for duration: BlitzDuration) -> Int { defaults.integer(forKey: key(duration)) }

    /// Records `score` and reports whether it beat the previous best. A tie is **not** a new
    /// best — matching `LocalOverUnderStore`, so "NEW BEST" always means the number moved.
    @discardableResult
    func recordScore(_ score: Int, for duration: BlitzDuration) -> Bool {
        guard score > highScore(for: duration) else { return false }
        defaults.set(score, forKey: key(duration))
        return true
    }
}
