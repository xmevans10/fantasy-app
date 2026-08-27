import SwiftUI

/// A daily "Who Am I?" puzzle: identify a mystery player from progressively revealed clues.
struct WhoAmIPuzzle: Identifiable, Codable, Equatable {
    let id: String
    let sport: Sport
    let clues: [Clue]            // ordered, 6 per the brief
    let answer: AcceptedAnswer
    /// How obscure the mystery player is, which scales the points on offer.
    ///
    /// **Optional, and nil means unrated rather than medium.** Content minted before this
    /// shipped has no tier, and a community puzzle never will — its subject was chosen by a
    /// person, so there's no fame percentile to derive one from. Defaulting those to `.medium`
    /// would have quietly multiplied every existing puzzle's score by 1.25 and stamped a
    /// difficulty on user-authored content the pipeline never assessed. Unrated puzzles score
    /// exactly as they did before (see `WhoAmIScoring.multiplier`) and show no chip.
    let difficulty: Difficulty?

    struct Clue: Codable, Equatable, Identifiable {
        let order: Int
        let kind: ClueKind
        let text: String
        /// The clue's real dimension name (`"draftPick"`, `"college"`, …) and its display
        /// label, written by the pipeline's clue library. Both nil on older content, which
        /// only ever carried the six `ClueKind`s.
        ///
        /// These exist because `kind` is a **wire-compatibility contract**, not a taxonomy:
        /// the shipped App Store build decodes `ClueKind` from a fixed six-value set, so the
        /// pipeline's ~30 dimensions all map onto those six and carry their real identity
        /// here, where an older client simply ignores them. See
        /// `tools/ingest/whoami_clues.py`'s module docstring for the full contract.
        let dimension: String?
        let label: String?

        var id: Int { order }

        /// What to show above the clue text — the pipeline's specific label when present,
        /// falling back to the legacy `kind`'s broad one.
        var displayLabel: String { label ?? kind.label }

        /// `dimension`/`label` default to nil so community authoring stays a three-argument
        /// call: `CreateWhoAmIView` offers exactly the six legacy `ClueKind`s, for which
        /// `kind.label` already *is* the right label — there's no extra dimension to name.
        init(order: Int, kind: ClueKind, text: String,
             dimension: String? = nil, label: String? = nil) {
            self.order = order
            self.kind = kind
            self.text = text
            self.dimension = dimension
            self.label = label
        }
    }

    struct AcceptedAnswer: Codable, Equatable {
        let canonical: String
        let aliases: [String]
    }

    /// `difficulty` defaults to nil (unrated) so `CreateWhoAmIView` and every test fixture
    /// stay four-argument calls. Decoding needs no custom `init(from:)`: an optional property
    /// is synthesized with `decodeIfPresent`, so a missing key is nil rather than a thrown
    /// error — which is exactly the behaviour the bundled pool and community rows need.
    init(id: String, sport: Sport, clues: [Clue], answer: AcceptedAnswer,
         difficulty: Difficulty? = nil) {
        self.id = id
        self.sport = sport
        self.clues = clues
        self.answer = answer
        self.difficulty = difficulty
    }
}

enum ClueKind: String, Codable {
    case era, position, teams, statLine, fact, jersey

    /// Sentence-case label (CDS). Broad by design — a clue's specific label now rides along
    /// in `Clue.label` (see `Clue.displayLabel`), and this is the fallback for content that
    /// predates it.
    var label: String {
        switch self {
        case .era: return String(localized: "Era")
        case .position: return String(localized: "Position")
        case .teams: return String(localized: "Teams")
        case .statLine: return String(localized: "Stat line")
        case .fact: return String(localized: "Known for")
        case .jersey: return String(localized: "Jersey")
        }
    }

    /// Unknown kinds decode as `.fact` instead of throwing.
    ///
    /// This is the forward-compatibility hole that constrains the whole clue pipeline today:
    /// the *shipped* build has no such fallback, so one unrecognized `kind` from Supabase
    /// fails the array decode and silently drops those users to the bundled 24-entry pool.
    /// That's why `tools/ingest/whoami_clues.py` maps ~30 dimensions onto these six values
    /// rather than adding cases here. With this in place, a future build can start emitting
    /// new kinds — but only once the versions without it have aged out.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ClueKind(rawValue: raw) ?? .fact
    }
}

/// Resolves the answer's headshot from catalog rows at reveal time — WhoAmI content itself
/// carries no photo URL (its content model predates M16 headshots), but the answer player
/// almost always has `player_seasons` rows. Deliberately conservative: exact normalized-name
/// equality only (never `AnswerMatcher`'s last-name/typo forgiveness — that leniency is for
/// grading a human's guess, not for picking whose face to show), and when the era clue's
/// span is parseable, only rows overlapping it count — so same-name players in one sport
/// (e.g. Jaren Jackson Sr./Jr., both in the NBA catalog) can never swap faces.
enum WhoAmIAnswerPhoto {
    /// "Played from 1992 to 2011" / "Played in 1998" → 1992...2011 / 1998...1998. The era
    /// clue is pipeline-generated content with a fixed shape (assemble.py `build_whoami_row`)
    /// and is never localized; nil when absent or if the shape ever changes.
    static func eraSpan(of puzzle: WhoAmIPuzzle) -> ClosedRange<Int>? {
        guard let text = puzzle.clues.first(where: { $0.kind == .era })?.text else { return nil }
        let years = text.split(whereSeparator: { !$0.isNumber })
            .compactMap { $0.count == 4 ? Int($0) : nil }
        guard let first = years.first, let last = years.last, first <= last else { return nil }
        return first...last
    }

    /// The catalog row this puzzle's answer resolves to, under the conservative rules above.
    /// `headshot(from:for:)` is a thin wrapper over this, so the two can never disagree about
    /// *which* player matched — the result screen paints the reveal in this row's club colours
    /// (M28 A5) and must be looking at the same player as the photo.
    ///
    /// Note this inherits the `headshot != nil` filter, so a subject with no photo also gets no
    /// club colour. That's deliberate: a second, looser match would resolve a team for players
    /// the strict rules rejected, and a *wrong* club colour on the reveal is worse than the
    /// neutral blue it falls back to.
    static func match(from rows: [CatalogSeason], for puzzle: WhoAmIPuzzle) -> CatalogSeason? {
        let accepted = Set(([puzzle.answer.canonical] + puzzle.answer.aliases)
            .map(AnswerMatcher.normalize))
        let span = eraSpan(of: puzzle)
        return rows
            .filter { row in
                guard let headshot = row.headshot, !headshot.isEmpty,
                      accepted.contains(AnswerMatcher.normalize(row.name)) else { return false }
                guard let span else { return true }
                let lo = row.firstYear ?? row.seasonYear
                let hi = Swift.max(lo, row.lastYear ?? row.seasonYear)
                return (lo...hi).overlaps(span)
            }
            .max { $0.seasonYear < $1.seasonYear }   // latest row → most recent photo
    }

    static func headshot(from rows: [CatalogSeason], for puzzle: WhoAmIPuzzle) -> String? {
        match(from: rows, for: puzzle)?.headshot
    }
}

/// Pure scoring for Who Am I? — earlier solve = more points, obscurer player = more points,
/// wrong guesses cost points.
enum WhoAmIScoring {
    static let perClue = [1000, 800, 600, 400, 200, 100]
    static let wrongPenalty = -100

    struct Result: Equatable {
        let cluesUsed: Int      // 1...6
        let wrongGuesses: Int
        let solved: Bool
        let total: Int
        /// Normalized 0...1 for the rating engine (clue efficiency; 0 if unsolved).
        let performance: Double
    }

    /// Score multiplier for a tier, with **nil (unrated) scoring exactly 1.0** — see
    /// `WhoAmIPuzzle.difficulty` for why unrated is its own thing rather than medium.
    static func multiplier(_ difficulty: WhoAmIPuzzle.Difficulty?) -> Double {
        difficulty?.multiplier ?? 1.0
    }

    /// Points on offer for solving on `cluesUsed` at `difficulty`, before penalties.
    ///
    /// The multiplier applies to the clue value, so the tier scales the whole curve rather
    /// than adding a flat bonus — solving a hard puzzle on clue 1 is worth the most, which is
    /// the behaviour the scoreboard should reward. The wrong-guess penalty is deliberately
    /// *not* scaled: a flat −100 keeps "guess wildly" equally unattractive at every tier.
    static func value(cluesUsed: Int, difficulty: WhoAmIPuzzle.Difficulty?) -> Int {
        let idx = min(max(cluesUsed - 1, 0), perClue.count - 1)
        return Int((Double(perClue[idx]) * multiplier(difficulty)).rounded())
    }

    /// The most a puzzle at `difficulty` can pay — a first-clue solve with no wrong guesses.
    static func maxScore(difficulty: WhoAmIPuzzle.Difficulty?) -> Int {
        value(cluesUsed: 1, difficulty: difficulty)
    }

    /// What unlocking clue number `n` costs, for `2...clues.count`. Clue 1 is always shown, so
    /// `cost(toUnlock: 1)` is 0.
    ///
    /// This is the whole price ladder the board renders now, not just the next step —
    /// `WhoAmIGameView.nextCueCost` is one call into it. Derived from `value(cluesUsed:)`
    /// rather than from `perClue` directly so the difficulty multiplier is applied exactly
    /// once, the same way the header's "Worth N pts" already does it.
    static func cost(toUnlock n: Int, difficulty: WhoAmIPuzzle.Difficulty?) -> Int {
        guard n > 1 else { return 0 }
        return value(cluesUsed: n - 1, difficulty: difficulty)
             - value(cluesUsed: n, difficulty: difficulty)
    }

    static func score(cluesUsed: Int, wrongGuesses: Int, solved: Bool,
                      difficulty: WhoAmIPuzzle.Difficulty? = nil) -> Result {
        let idx = min(max(cluesUsed - 1, 0), perClue.count - 1)
        let base = solved ? value(cluesUsed: cluesUsed, difficulty: difficulty) : 0
        let total = max(0, base + wrongGuesses * wrongPenalty)
        // Deliberately difficulty-INDEPENDENT: `performance` feeds the competitive rating
        // engine, and it means "how efficiently was this puzzle solved" (clues used), not
        // "how impressive was it". Folding the multiplier in here would let the tier the
        // pipeline happened to serve move a player's rating, which is a scoring change
        // masquerading as a content change. Difficulty pays out in points and XP only.
        let performance = solved ? Double(perClue[idx]) / Double(perClue[0]) : 0
        return Result(cluesUsed: cluesUsed, wrongGuesses: wrongGuesses,
                      solved: solved, total: total, performance: performance)
    }
}

/// Forgiving answer matching: normalize, accept canonical/aliases/last-name, allow 1 typo.
enum AnswerMatcher {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ guess: String, answer: WhoAmIPuzzle.AcceptedAnswer) -> Bool {
        let g = normalize(guess)
        guard !g.isEmpty else { return false }

        var accepted = Set<String>()
        for raw in [answer.canonical] + answer.aliases {
            let n = normalize(raw)
            accepted.insert(n)
            if let last = n.split(separator: " ").last, last.count >= 4 {
                accepted.insert(String(last))   // accept distinctive last name
            }
        }

        for target in accepted {
            if g == target { return true }
            // allow a single-character typo on longer answers
            if target.count >= 5, levenshtein(g, target) <= 1 { return true }
        }
        return false
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
