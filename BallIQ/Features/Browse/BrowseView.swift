import SwiftUI

/// Archive of every daily puzzle (not just today's). Playing from here is **unranked**
/// (XP only) — replaying past dailies shouldn't move the competitive rating. Mirrors the
/// Community browse layout; reads the full pool via `PuzzleRepository.all*`.
///
/// With `pinnedFormat` set this doubles as a per-format **hub** (opened from Home's format
/// tiles, 2026-07-17 IA fix): today's *ranked* daily leads, the archive follows, and the
/// format dropdown disappears. The tiles used to dead-end into today's daily only while
/// the whole replayable library hid behind the quiet Browse row — the hub makes a format
/// tile mean "play this format", not "play today's one puzzle". Archive plays stay
/// Pro-gated at the row tap (free users can see the shelf; playing it sells Pro).
struct BrowseView: View {
    @EnvironmentObject private var container: RepositoryContainer

    /// When set, this screen is that format's hub: no format dropdown, daily-first layout.
    let pinnedFormat: BrowseFormat?

    init(pinnedFormat: BrowseFormat? = nil) {
        self.pinnedFormat = pinnedFormat
        _format = State(initialValue: pinnedFormat ?? .keep4)
    }

    @State private var format: BrowseFormat
    @State private var sportFilter: SportFilter = .all
    @State private var decadeFilter: DecadeFilter = .all
    @State private var grainFilter: GrainFilter = .all
    @State private var searchText = ""
    @State private var searchExpanded = false
    @State private var keep4: [Keep4Puzzle] = []
    @State private var whoami: [WhoAmIPuzzle] = []
    @State private var journeyman: [JourneymanPuzzle] = []
    @State private var dailyKeep4: DailyPick<Keep4Puzzle>?
    @State private var dailyWhoAmI: DailyPick<WhoAmIPuzzle>?
    @State private var dailyJourneyman: DailyPick<JourneymanPuzzle>?
    @State private var loading = false

    @State private var activeKeep4: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?
    @State private var activeJourneyman: JourneymanPuzzle?
    @State private var activeDailyKeep4: Keep4Puzzle?
    @State private var activeDailyWhoAmI: WhoAmIPuzzle?
    @State private var activeDailyJourneyman: JourneymanPuzzle?
    @State private var shareTarget: SharablePuzzle?
    @State private var showPaywall = false

    enum BrowseFormat: String, CaseIterable {
        case keep4, whoami, journeyman
        var title: String {
            switch self {
            case .keep4: return "K4C4"
            case .whoami: return "Who Am I?"
            case .journeyman: return "Journeyman"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().overlay(Color.hairline)
            content
        }
        .background(Color.appBackground)
        .navigationTitle(pinnedFormat?.title ?? "Browse")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshKey) { await load() }
        .fullScreenCover(item: $activeKeep4) { p in
            Keep4GameView(puzzle: p, ranked: false).environmentObject(container)
        }
        .fullScreenCover(item: $activeWhoAmI) { p in
            WhoAmIGameView(puzzle: p, ranked: false).environmentObject(container)
        }
        .fullScreenCover(item: $activeJourneyman) { p in
            JourneymanGameView(puzzle: p, ranked: false).environmentObject(container)
        }
        // Today's daily from the hub is the real ranked run — same semantics as Home's
        // daily cards, distinct from the unranked archive covers above.
        .fullScreenCover(item: $activeDailyKeep4) { p in
            Keep4GameView(puzzle: p).environmentObject(container)
        }
        .fullScreenCover(item: $activeDailyWhoAmI) { p in
            WhoAmIGameView(puzzle: p).environmentObject(container)
        }
        .fullScreenCover(item: $activeDailyJourneyman) { p in
            JourneymanGameView(puzzle: p).environmentObject(container)
        }
        .sheet(item: $shareTarget) { target in
            PuzzleShareSheet(puzzle: target, surface: "puzzle_browse")
                .environmentObject(container)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(trigger: .archive).environmentObject(container)
        }
    }

    private var refreshKey: String { "\(format.rawValue)-\(sportFilter.rawValue)" }
    private var currentEmpty: Bool {
        switch format {
        case .keep4: return filteredKeep4.isEmpty
        case .whoami: return whoami.isEmpty
        case .journeyman: return journeyman.isEmpty
        }
    }

    // MARK: - Controls

    /// One collapsed control row instead of a stack of always-expanded chip rows: Format/
    /// Sport/Decade/Depth are `PrimeDropdown`s (native `Menu`), search collapses to an icon
    /// until tapped. Search only applies to K4C4 — Who Am I? archive cards are deliberately
    /// anonymous ("Mystery player #n"); searching would leak answers — so it and Decade/Depth
    /// (K4C4-only facets, see `BrowseFilters`) drop out of the row for that tab.
    private var controls: some View {
        HStack(spacing: 8) {
            if searchExpanded {
                PrimeExpandingSearch(placeholder: String(localized: "Search themes or players"),
                                    text: $searchText, isExpanded: $searchExpanded)
            } else {
                // Chips scroll rather than compress: four dropdowns + search can't share
                // one screen width without truncating into meaningless "SPO…"/"DEC…" —
                // the whole point of the dimension labels is that they stay readable.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if pinnedFormat == nil {
                            PrimeDropdown(options: BrowseFormat.allCases, selection: $format,
                                         title: \.title, isDefault: { _ in false })
                        }
                        PrimeDropdown(options: SportFilter.allCases, selection: $sportFilter, title: \.title,
                                      unsetLabel: String(localized: "Sport"))
                        if format == .keep4 {
                            PrimeDropdown(options: DecadeFilter.allCases, selection: $decadeFilter, title: \.title,
                                          unsetLabel: String(localized: "Decade"))
                            PrimeDropdown(options: GrainFilter.allCases, selection: $grainFilter, title: \.title,
                                          unsetLabel: String(localized: "Depth"))
                        }
                    }
                }
                Spacer(minLength: 0)
                if format == .keep4 {
                    PrimeExpandingSearch(placeholder: String(localized: "Search themes or players"),
                                        text: $searchText, isExpanded: $searchExpanded)
                }
            }
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if loading && currentEmpty && dailyPuzzleMissing {
            Spacer(); ProgressView().tint(.accentFill); Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if pinnedFormat != nil {
                        LowerThirdHeader(title: "Today's daily")
                        dailySection
                        LowerThirdHeader(title: "Archive")
                            .padding(.top, 10)
                    }
                    if currentEmpty {
                        emptyState.frame(maxWidth: .infinity)
                    } else if format == .keep4 {
                        ForEach(numberedKeep4, id: \.puzzle.id) { card(keep4: $0.puzzle, title: $0.title) }
                    } else if format == .whoami {
                        ForEach(Array(whoami.enumerated()), id: \.element.id) { i, p in
                            card(whoAmI: p, number: i + 1)
                        }
                    } else {
                        ForEach(teasedJourneyman, id: \.puzzle.id) {
                            card(journeyman: $0.puzzle, title: $0.title)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var dailyPuzzleMissing: Bool {
        guard pinnedFormat != nil else { return true }
        switch format {
        case .keep4: return dailyKeep4 == nil
        case .whoami: return dailyWhoAmI == nil
        case .journeyman: return dailyJourneyman == nil
        }
    }

    /// Today's ranked daily for the chosen sport — the same card Home shows, so the hub
    /// reads as "the daily, then everything else this format has".
    @ViewBuilder private var dailySection: some View {
        if format == .keep4, let pick = dailyKeep4 {
            let p = pick.content
            DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill", sport: p.sport,
                          title: p.theme, subtitle: "\(p.players.count) \(p.puzzleGrain().countNoun)",
                          scoring: p.scoringKind(), grain: p.puzzleGrain(),
                          completed: container.hasCompletedToday(puzzleID: p.id),
                          favoriteTeamMatch: container.favoriteTeams.team(for: p.sport)
                              .map(p.features(teamAbbr:)) ?? false,
                          ranked: true,
                          dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                activeDailyKeep4 = p
            }
            secondaryAction: { shareTarget = SharablePuzzle(keep4: p) }
        } else if format == .whoami, let pick = dailyWhoAmI {
            let p = pick.content
            DailyGameCard(formatName: "Who am I?", symbol: "questionmark.circle.fill", sport: p.sport,
                          title: String(localized: "Guess today's mystery player"),
                          subtitle: String(localized: "\(p.clues.count) clues"),
                          difficulty: p.difficulty,
                          completed: container.hasCompletedToday(puzzleID: p.id),
                          typeColor: .voltFill, onTypeColor: .onVolt,
                          ranked: true,
                          dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                activeDailyWhoAmI = p
            }
            secondaryAction: { shareTarget = SharablePuzzle(whoAmI: p) }
        } else if format == .journeyman, let pick = dailyJourneyman {
            let p = pick.content
            DailyGameCard(formatName: "Journeyman", symbol: "arrow.triangle.branch", sport: p.sport,
                          title: String(localized: "Name the player from their clubs"),
                          subtitle: String(localized: "\(p.stints.count) clubs"),
                          difficulty: p.difficulty,
                          completed: container.hasCompletedToday(puzzleID: p.id),
                          typeColor: .goldFill, onTypeColor: .onGold,
                          ranked: true,
                          dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                activeDailyJourneyman = p
            }
        }
    }

    private var filteredKeep4: [Keep4Puzzle] {
        keep4.filter {
            BrowseFilters.matchesDecade($0, filter: decadeFilter) &&
                BrowseFilters.matchesGrain($0, filter: grainFilter) &&
                PuzzleSearch.matches(query: searchText, keep4: $0)
        }
    }

    /// Deliberately **not** numbered the way repeated Keep4 themes are below. A theme name is an
    /// identity, so "Best Season #2" is useful; a teaser is a joke, and 150 archive boards drawn
    /// from ~21 lines means almost every card would carry a "#n" — which is the filing label this
    /// replaced, stapled onto the punchline. The list is keyed on `puzzle.id`, and a repeated
    /// line costs a browsing player nothing.
    private var teasedJourneyman: [(puzzle: JourneymanPuzzle, title: String)] {
        // The minted teaser knows who the player is; the local one only knows the shape of the
        // path. Prefer the real thing, fall back so a pre-teaser or hand-authored board still
        // gets a title rather than a blank card.
        journeyman.map { ($0, $0.teaser ?? JourneymanTeaser.line(for: $0)) }
    }

    /// Themes repeat across many distinct puzzles, so number duplicates ("… #2") to tell them apart.
    private var numberedKeep4: [(puzzle: Keep4Puzzle, title: String)] {
        let visible = filteredKeep4
        let totals = Dictionary(grouping: visible, by: \.theme).mapValues(\.count)
        var seen: [String: Int] = [:]
        return visible.map { p in
            seen[p.theme, default: 0] += 1
            let title = (totals[p.theme] ?? 1) > 1 ? "\(p.theme) #\(seen[p.theme]!)" : p.theme
            return (p, title)
        }
    }

    /// Archive plays are the Pro pillar — from the hub, free users see the shelf but the
    /// row tap paywalls (the Home Browse row gates at entry, so Pro users never hit this).
    private func playArchive(_ open: () -> Void) {
        if container.entitlements.canAccessArchive { open() } else { showPaywall = true }
    }

    private func card(keep4 p: Keep4Puzzle, title: String) -> some View {
        DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill", sport: p.sport,
                      title: title, subtitle: "\(p.players.count) \(p.puzzleGrain().countNoun) · archive",
                      scoring: p.scoringKind(), grain: p.puzzleGrain(),
                      completed: container.hasCompletedToday(puzzleID: p.id),
                      favoriteTeamMatch: container.favoriteTeams.team(for: p.sport).map(p.features(teamAbbr:)) ?? false) {
            playArchive { activeKeep4 = p }
        }
        secondaryAction: { shareTarget = SharablePuzzle(keep4: p) }
    }

    /// Who Am I? has no title (revealing one would spoil the answer) — show a neutral numbered label.
    private func card(whoAmI p: WhoAmIPuzzle, number: Int) -> some View {
        DailyGameCard(formatName: "Who am I?", symbol: "questionmark.circle.fill", sport: p.sport,
                      title: "Mystery player #\(number)", subtitle: "\(p.clues.count) clues · archive",
                      difficulty: p.difficulty,
                      completed: container.hasCompletedToday(puzzleID: p.id), typeColor: .voltFill, onTypeColor: .onVolt) {
            playArchive { activeWhoAmI = p }
        }
        secondaryAction: { shareTarget = SharablePuzzle(whoAmI: p) }
    }

    /// Titled with a joke about the shape of the career (`JourneymanTeaser`) rather than the
    /// filing label these carried first ("Career path #7"), which told a browsing player nothing
    /// and invited nobody. The teaser is derived only from the path, so it can't leak the answer
    /// — see that type. The club count stays: the board shows it in the first second anyway, and
    /// it's what tells a browser which boards look long.
    private func card(journeyman p: JourneymanPuzzle, title: String) -> some View {
        DailyGameCard(formatName: "Journeyman", symbol: "arrow.triangle.branch", sport: p.sport,
                      title: title,
                      subtitle: String(localized: "\(p.stints.count) clubs · archive"),
                      difficulty: p.difficulty,
                      completed: container.hasCompletedToday(puzzleID: p.id),
                      typeColor: .goldFill, onTypeColor: .onGold) {
            playArchive { activeJourneyman = p }
        }
    }

    private var emptyState: some View {
        let filtersActive = format == .keep4 &&
            (decadeFilter != .all || grainFilter != .all || !searchText.isEmpty)
        return EmptyStateView(symbol: filtersActive ? "line.3.horizontal.decrease.circle" : "tray.full",
                              title: filtersActive ? "No puzzles match" : "Nothing here yet",
                              message: filtersActive
                                  ? "Try a different search, decade, or depth."
                                  : "Daily puzzles will fill this archive.")
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        switch format {
        case .keep4: keep4 = await container.puzzles.allKeep4(for: sportFilter)
        case .whoami: whoami = await container.puzzles.allWhoAmI(for: sportFilter)
        case .journeyman: journeyman = await container.puzzles.allJourneyman(for: sportFilter)
        }
        if pinnedFormat != nil {
            switch format {
            case .keep4:
                dailyKeep4 = await container.puzzles.keep4Puzzle(for: sportFilter, date: Date())
            case .whoami:
                dailyWhoAmI = await container.puzzles.whoAmIPuzzle(for: sportFilter, date: Date())
            case .journeyman:
                dailyJourneyman = await container.puzzles.journeymanPuzzle(for: sportFilter, date: Date())
            }
        }
        if let query = DebugLaunch.searchQuery { searchText = query }
        if let sport = DebugLaunch.browseSport, let filter = SportFilter(rawValue: sport) {
            sportFilter = filter
        }
        if DebugLaunch.autoOpenShare, shareTarget == nil, let first = filteredKeep4.first {
            shareTarget = SharablePuzzle(keep4: first)
        }
    }
}
