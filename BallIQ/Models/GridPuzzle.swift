import Foundation

/// The Grid (M5 Phase E, Pro-only): a 3x3 board generated server-side by `tools/ingest/grid.py`
/// with a viability guarantee (every cell has >=1 real answer). Content shape mirrors
/// `grid.to_content(...)`'s camelCase JSON exactly.
///
/// Until 2026-07-27 the board was always teams x decades — `rowTeams: [String]` crossed with
/// `colDecades: [Int]`, hardcoded here and in the layout. It is now symmetric: rows and columns
/// are both `[GridAxis]`, and an axis may be a team, a decade, a position, or a statistical
/// milestone, in any combination (see docs/grid-axes-research.md for the Immaculate Grid
/// research behind that). This type decodes **both** shapes — a v1 board minted before the
/// change is immutable for its day and players may be mid-grid when a new build ships, so the
/// old keys have to keep working rather than showing "No Grid today".
struct GridPuzzle: Codable, Equatable, SportScoped {
    let sport: Sport
    let rows: [GridAxis]
    let cols: [GridAxis]
    let cells: [GridCell]
    /// Which board shape the generator produced ("teams-x-stats", "teams-x-teams", …). Empty for
    /// legacy content. Carried for telemetry and for the footer's how-to-play line.
    let archetype: String

    /// One row or column. `kind` is what tells the client HOW to draw the label — a team axis
    /// gets the real crest + color chip, everything else is a text label — which is why it's
    /// decoded rather than inferred from the label's shape.
    struct GridAxis: Codable, Equatable {
        let kind: Kind
        let label: String
        /// Team axes only: the franchise's real identity. `label` is not enough on its own —
        /// soccer abbreviations are derived and collide across countries, so "MCI" is both
        /// Manchester City and Melbourne City (51 of 954 soccer codes are genuinely shared).
        /// Without the league the crest and colors resolve to whichever club
        /// `TeamIdentityIndex` happens to match first, so a correct answer set would still
        /// render the wrong badge.
        let abbr: String?
        let league: String?

        init(kind: Kind, label: String, abbr: String? = nil, league: String? = nil) {
            self.kind = kind
            self.label = label
            self.abbr = abbr
            self.league = league
        }

        /// What the crest/color lookup should key on. Falls back to the label for legacy content
        /// (pre-2026-07-27 boards carry only `rowTeams`).
        var teamAbbr: String { abbr ?? label }
        /// Empty string means "no league given" — `TeamIdentityIndex` already treats nil as
        /// "match any league", which is the right behaviour for the US sports.
        var teamLeague: String? { (league?.isEmpty == false) ? league : nil }

        /// Unknown kinds decode to `.other` rather than failing the whole puzzle: the generator
        /// can add an axis kind (awards, college, draft) before a client build ships that knows
        /// how to special-case it, and "render it as a text label" is always a correct fallback.
        enum Kind: String, Codable {
            case team, decade, position, stat, other

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .other
            }
        }
    }

    struct GridCell: Codable, Equatable {
        let validAnswerIds: [String]
        let validAnswerNames: [String]
        let rarityStars: Int
    }

    func cell(row: Int, col: Int) -> GridCell { cells[row * 3 + col] }

    /// Whether `guess` matches one of this cell's valid answers — same tolerant matching
    /// (case-insensitive, last-name-only, single-typo) WhoAmI already uses, reused rather
    /// than reinventing a second free-text matcher. No aliases here (Grid's content only
    /// carries canonical names), so each candidate is wrapped as its own bare `AcceptedAnswer`.
    func isCorrect(row: Int, col: Int, guess: String) -> Bool {
        let candidates = cell(row: row, col: col).validAnswerNames
        return candidates.contains {
            AnswerMatcher.matches(guess, answer: .init(canonical: $0, aliases: []))
        }
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case sport, rows, cols, cells, archetype
        case rowTeams, colDecades       // legacy (pre-2026-07-27) teams x decades shape
    }

    init(sport: Sport, rows: [GridAxis], cols: [GridAxis], cells: [GridCell], archetype: String = "") {
        self.sport = sport
        self.rows = rows
        self.cols = cols
        self.cells = cells
        self.archetype = archetype
    }

    /// Prefers the symmetric `rows`/`cols` payload, falling back to synthesising axes from the
    /// legacy `rowTeams`/`colDecades`. The generator still emits the legacy keys alongside the
    /// new ones whenever a board happens to be the classic teams x decades shape, so this
    /// fallback only actually fires for rows minted before the change.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sport = try c.decode(Sport.self, forKey: .sport)
        cells = try c.decode([GridCell].self, forKey: .cells)
        archetype = (try? c.decode(String.self, forKey: .archetype)) ?? ""
        if let rows = try? c.decode([GridAxis].self, forKey: .rows),
           let cols = try? c.decode([GridAxis].self, forKey: .cols) {
            self.rows = rows
            self.cols = cols
        } else {
            let teams = try c.decode([String].self, forKey: .rowTeams)
            let decades = try c.decode([Int].self, forKey: .colDecades)
            self.rows = teams.map { GridAxis(kind: .team, label: $0) }
            self.cols = decades.map { GridAxis(kind: .decade, label: "\($0)s") }
        }
    }

    /// Always encodes the modern shape. Encoding only happens for test fixtures and the
    /// render-gallery, never to write content back to the server, so there's no reason to
    /// reproduce the legacy keys here.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sport, forKey: .sport)
        try c.encode(rows, forKey: .rows)
        try c.encode(cols, forKey: .cols)
        try c.encode(cells, forKey: .cells)
        try c.encode(archetype, forKey: .archetype)
    }
}

extension GridPuzzle {
    /// The guess-sheet prompt for a cell, e.g. "KC · 2000s" or "DAL · 1,000+ Rush Yds".
    ///
    /// Replaces the old hardcoded `"\(team) in the \(decade)s"` — with symmetric axes there is no
    /// longer a team side and an era side to interpolate, and phrasing that assumed one produced
    /// nonsense the moment a board was teams x teams ("PIT in the CARs").
    func prompt(row: Int, col: Int) -> String {
        "\(rows[row].label.uppercased()) · \(cols[col].label.uppercased())"
    }

    /// The board's how-to-play line, phrased for the shape actually on screen. Teams x teams asks
    /// a career question ("played for both"); every other shape asks about a single season.
    var instructions: String {
        archetype == "teams-x-teams"
            ? "Tap a cell and name a player who played for both clubs. One guess per cell."
            : "Tap a cell and name a player who fits both the row and the column. One guess per cell."
    }
}
