import SwiftUI

/// One board a blitz can serve, plus the identity the run needs to record it.
///
/// Mirrors `DuelBoard` — the same "one case per format, because the game views take genuinely
/// different content types" reasoning applies here for the same reason, and the same payoff: a
/// change to how a blitz board is presented is one edit rather than four.
enum BlitzBoard: Identifiable, Equatable {
    case keep4(Keep4Puzzle)
    case whoami(WhoAmIPuzzle)
    case journeyman(JourneymanPuzzle)
    /// Over/Under carries its sport alongside the round: an `OverUnderRound` is generated from a
    /// catalog pool and, unlike the three content types above, doesn't record which sport it came
    /// from.
    case overunder(OverUnderRound, Sport)

    var format: BlitzFormat {
        switch self {
        case .keep4:      return .keep4
        case .whoami:     return .whoami
        case .journeyman: return .journeyman
        case .overunder:  return .overunder
        }
    }

    var sport: Sport {
        switch self {
        case .keep4(let p):        return p.sport
        case .whoami(let p):       return p.sport
        case .journeyman(let p):   return p.sport
        case .overunder(_, let s): return s
        }
    }

    /// The id recorded for this board. For the three row-backed formats it is the real
    /// `puzzles.id`; for Over/Under it is the generator's own synthetic round id, which is the
    /// only identifier that round will ever have.
    var puzzleID: String {
        switch self {
        case .keep4(let p):      return p.id
        case .whoami(let p):     return p.id
        case .journeyman(let p): return p.id
        case .overunder(let r, _): return r.id
        }
    }

    var id: String { "\(format.rawValue)-\(puzzleID)" }
}

/// Draws the next random board for a blitz run.
///
/// **Pools are fetched once per (sport, format) and then drawn from in memory**, because a blitz
/// serves a board every few seconds and cannot afford a round trip between them. The underlying
/// `RemotePuzzleRepository` disk-caches each pool anyway, so the first draw for a pair is the
/// only real network hit and every board after it is instant.
@MainActor
final class BlitzRoundLoader {
    private let container: RepositoryContainer
    private let config: BlitzConfig

    /// Loaded board pools, keyed by the (sport, format) pair they were fetched for. A key present
    /// with an empty array means "fetched, genuinely nothing there" — that pair is then dropped
    /// from the draw rather than re-fetched on every board.
    private var keep4: [Sport: [Keep4Puzzle]] = [:]
    private var whoami: [Sport: [WhoAmIPuzzle]] = [:]
    private var journeyman: [Sport: [JourneymanPuzzle]] = [:]
    private var overUnderPool: [Sport: [CatalogSeason]] = [:]

    /// Boards already served this run. A blitz that repeats a board inside one run is a blitz the
    /// player can farm by memory, so this is a correctness constraint, not polish.
    private var served: Set<String> = []

    /// Today's canonical daily for each (sport, format), withheld from the draw.
    ///
    /// Not an optimisation — a spoiler guard. Serving today's unplayed K4C4 as a throwaway blitz
    /// board would hand the player the answer to the ranked daily they haven't taken yet, which is
    /// the same failure `RemotePuzzleRepository.released` exists to prevent one day earlier.
    /// Withheld unconditionally rather than only when unplayed: "you already did it" is state this
    /// would have to re-read per board, and the pools are deep enough that one row costs nothing.
    private var withheld: Set<String> = []

    init(container: RepositoryContainer, config: BlitzConfig) {
        self.container = container
        self.config = config
    }

    /// Fetches every pool the chosen mix can draw from, in parallel, and reports whether *any*
    /// board is available. A false return is a real empty state (no content for this
    /// sport/format mix), not a transient failure to retry.
    func warm() async -> Bool {
        for sport in config.orderedSports {
            let filter = SportFilter(rawValue: sport.rawValue) ?? .all
            // Independent reads for one sport, started together — the same round-trip saving
            // `HomeView.loadDaily(for:)` makes, and the reason a cold blitz opens in about the
            // time one fetch takes rather than four.
            async let keep4Pool = config.formats.contains(.keep4)
                ? container.puzzles.allKeep4(for: filter) : []
            async let whoamiPool = config.formats.contains(.whoami)
                ? container.puzzles.allWhoAmI(for: filter) : []
            // `isAvailable(for:)` short-circuits the one structurally impossible pairing
            // (Journeyman + tennis, see `Sport.hasClubCareers`) so a tennis blitz doesn't spend a
            // round trip fetching a pool the server will always answer empty.
            async let journeymanPool = config.formats.contains(.journeyman)
                && BlitzFormat.journeyman.isAvailable(for: sport)
                ? container.puzzles.allJourneyman(for: filter) : []
            async let arcadePool = config.formats.contains(.overunder)
                ? container.catalog.arcadePool(for: sport, limit: 200) : []
            // Today's canonical rows, so they can be held back (see `withheld`).
            async let todayKeep4 = config.formats.contains(.keep4)
                ? container.puzzles.keep4Puzzle(for: filter, date: Date()) : nil
            async let todayWhoAmI = config.formats.contains(.whoami)
                ? container.puzzles.whoAmIPuzzle(for: filter, date: Date()) : nil
            async let todayJourneyman = config.formats.contains(.journeyman)
                && BlitzFormat.journeyman.isAvailable(for: sport)
                ? container.puzzles.journeymanPuzzle(for: filter, date: Date()) : nil

            keep4[sport] = await keep4Pool
            whoami[sport] = await whoamiPool
            journeyman[sport] = await journeymanPool
            overUnderPool[sport] = PlayerRelevance.filter(await arcadePool, sport: sport, minimum: 20)

            if let pick = await todayKeep4, pick.isCanonicalToday { withheld.insert(pick.content.id) }
            if let pick = await todayWhoAmI, pick.isCanonicalToday { withheld.insert(pick.content.id) }
            if let pick = await todayJourneyman, pick.isCanonicalToday { withheld.insert(pick.content.id) }

            warmImages(for: sport)
        }
        return next() != nil
    }

    /// How many boards' worth of art to warm per sport. A blitz is a handful of boards (see
    /// `BlitzConfig.estimatedBoards`), and a Keep4 board is 8 photos, so this covers most of a
    /// run without pulling a whole pool the player will never reach.
    private static let prewarmBoardsPerSport = 4

    /// Warm the images a run is *likely* to draw, while the pools are loading and before the
    /// clock starts.
    ///
    /// Blitz was the worst surface in the app for this and had no image warming at all: every
    /// other format is entered from Home, which has been warming its dailies for a while, but a
    /// blitz draws random boards from a pool nobody has looked at. So every headshot and crest
    /// was fetched at the moment its board appeared — against a clock, which is precisely when a
    /// player cannot afford to wait for one.
    ///
    /// Boards are drawn randomly by `next()`, so exactly which ones come up isn't knowable here;
    /// warming a bounded random sample of each pool covers most of a short run, and anything
    /// missed still benefits from the per-board warm in `next()`.
    private func warmImages(for sport: Sport) {
        var headshots: [String] = []
        var crestAbbrs: [String] = []

        for puzzle in (keep4[sport] ?? []).shuffled().prefix(Self.prewarmBoardsPerSport) {
            headshots.append(contentsOf: puzzle.players.compactMap(\.headshot))
            crestAbbrs.append(contentsOf: puzzle.players.map(\.teamAbbr))
        }
        for puzzle in (journeyman[sport] ?? []).shuffled().prefix(Self.prewarmBoardsPerSport) {
            if let headshot = puzzle.headshot { headshots.append(headshot) }
            crestAbbrs.append(contentsOf: puzzle.stints.map(\.teamAbbr))
        }
        // Over/Under rounds are generated from this pool rather than drawn from it, so the whole
        // sampled slice is a fair candidate set.
        for season in (overUnderPool[sport] ?? []).shuffled().prefix(Self.prewarmBoardsPerSport * 3) {
            if let headshot = season.headshot { headshots.append(headshot) }
            crestAbbrs.append(season.teamAbbr)
        }
        // Who Am I? is absent on purpose, the same reason `PuzzleImageWarmer.warmDailies` skips
        // it: its photo is the answer, so warming it would be pre-fetching a spoiler.

        PuzzleImageWarmer.warm(urls: headshots, targetSize: AppImagePipeline.cardWarmSize)
        PuzzleImageWarmer.warmCrests(sport: sport, abbrs: crestAbbrs)
    }

    /// The next board, or nil when the chosen mix has nothing left to serve.
    ///
    /// **Uniform over the formats that can still produce a board, not weighted by how long they
    /// take.** A time-weighted draw would flood the run with Over/Under (an 8-second par against
    /// K4C4's 120), which is a different game from the one the player ticked four boxes for. The
    /// consequence — a five-minute all-formats run is only a handful of boards — is surfaced
    /// honestly on the setup screen instead (`BlitzConfig.estimatedBoards`), so trimming the mix
    /// for a faster blitz is the player's dial rather than the loader's opinion.
    ///
    /// Randomness is real (`randomElement()`, no seed): BALLIQ_SPEC §1 theme 4 reserves
    /// determinism for shared dailies and asks for genuine randomness in arcade formats, and a
    /// blitz is nobody else's board.
    func next() -> BlitzBoard? {
        // Draw a format that can actually serve, retrying against a shrinking candidate set so
        // one exhausted format can't end a run the others could still fill.
        var candidates = config.servableFormats
        while let format = candidates.randomElement() {
            if let board = draw(format) {
                served.insert(board.id)
                // Backstop for anything the sampled pre-warm in `warm()` missed. The board is
                // about to be built and rendered, so this is a head start of only a frame or two
                // — worth having, not enough on its own, which is why the pool sample exists.
                warmImages(for: board)
                return board
            }
            candidates.removeAll { $0 == format }
        }
        return nil
    }

    /// The art one specific board will render.
    private func warmImages(for board: BlitzBoard) {
        switch board {
        case .keep4(let puzzle):
            PuzzleImageWarmer.warm(keep4: puzzle)
        case .journeyman(let puzzle):
            PuzzleImageWarmer.warm(journeyman: puzzle)
            PuzzleImageWarmer.warmCrests(sport: puzzle.sport, abbrs: puzzle.stints.map(\.teamAbbr))
        case .overunder(let round, let sport):
            PuzzleImageWarmer.warm(urls: [round.player.headshot].compactMap { $0 },
                                   targetSize: AppImagePipeline.cardWarmSize)
            PuzzleImageWarmer.warmCrests(sport: sport, abbrs: [round.player.teamAbbr])
        case .whoami:
            break   // the photo is the answer — see `warmImages(for sport:)`
        }
    }

    private func draw(_ format: BlitzFormat) -> BlitzBoard? {
        // Sports are shuffled rather than iterated so a multi-sport run doesn't systematically
        // favour whichever sport sorts first in `Sport.allCases`.
        for sport in config.orderedSports.shuffled() where format.isAvailable(for: sport) {
            switch format {
            case .keep4:
                if let p = pick(keep4[sport] ?? [], id: \.id, format: .keep4) { return .keep4(p) }
            case .whoami:
                if let p = pick(whoami[sport] ?? [], id: \.id, format: .whoami) { return .whoami(p) }
            case .journeyman:
                if let p = pick(journeyman[sport] ?? [], id: \.id, format: .journeyman) {
                    return .journeyman(p)
                }
            case .overunder:
                if let round = drawOverUnder(sport) { return .overunder(round, sport) }
            }
        }
        return nil
    }

    /// A pool member that hasn't been served this run and isn't today's withheld daily.
    private func pick<P>(_ pool: [P], id: KeyPath<P, String>, format: BlitzFormat) -> P? {
        pool.filter { !withheld.contains($0[keyPath: id])
                   && !served.contains("\(format.rawValue)-\($0[keyPath: id])") }
            .randomElement()
    }

    /// Over/Under rounds are generated, not drawn from a fixed pool, so "already served" is about
    /// the generator index rather than a row. A random index (not a running counter) keeps the
    /// sequence genuinely random; the bounded retry covers the vanishing chance of a collision or
    /// of an index whose player has no position-scoped stat to build a line from.
    private func drawOverUnder(_ sport: Sport) -> OverUnderRound? {
        let pool = overUnderPool[sport] ?? []
        guard !pool.isEmpty else { return nil }
        for _ in 0..<8 {
            let index = Int.random(in: 0..<1_000_000)
            guard let round = OverUnderRoundGenerator.round(from: pool, sport: sport,
                                                            date: Date(), index: index) else { continue }
            if !served.contains("\(BlitzFormat.overunder.rawValue)-\(round.id)") { return round }
        }
        return nil
    }
}
