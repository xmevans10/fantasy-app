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
    @State private var dailyKeep4: Keep4Puzzle?
    @State private var dailyWhoAmI: WhoAmIPuzzle?
    @State private var loading = false

    @State private var activeKeep4: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?
    @State private var activeDailyKeep4: Keep4Puzzle?
    @State private var activeDailyWhoAmI: WhoAmIPuzzle?
    @State private var shareTarget: SharablePuzzle?
    @State private var showPaywall = false

    enum BrowseFormat: String, CaseIterable {
        case keep4, whoami
        var title: String { self == .keep4 ? "K4C4" : "Who Am I?" }
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
        // Today's daily from the hub is the real ranked run — same semantics as Home's
        // daily cards, distinct from the unranked archive covers above.
        .fullScreenCover(item: $activeDailyKeep4) { p in
            Keep4GameView(puzzle: p).environmentObject(container)
        }
        .fullScreenCover(item: $activeDailyWhoAmI) { p in
            WhoAmIGameView(puzzle: p).environmentObject(container)
        }
        .sheet(item: $shareTarget) { target in
            PuzzleShareSheet(puzzle: target, surface: "puzzle_browse")
                .environmentObject(container)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(container)
        }
    }

    private var refreshKey: String { "\(format.rawValue)-\(sportFilter.rawValue)" }
    private var currentEmpty: Bool { format == .keep4 ? filteredKeep4.isEmpty : whoami.isEmpty }

    // MARK: - Controls

    /// One collapsed control row instead of a stack of always-expanded chip rows: Format/
    /// Sport/Decade/Depth are `PrimeDropdown`s (native `Menu`), search collapses to an icon
    /// until tapped. Search only applies to K4C4 — Who Am I? archive cards are deliberately
    /// anonymous ("Mystery player #n"); searching would leak answers — so it and Decade/Depth
    /// (K4C4-only facets, see `BrowseFilters`) drop out of the row for that tab.
    private var controls: some View {
        HStack(spacing: 8) {
            if searchExpanded {
                PrimeExpandingSearch(placeholder: "Search themes or players",
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
                    PrimeExpandingSearch(placeholder: "Search themes or players",
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
                    } else {
                        ForEach(Array(whoami.enumerated()), id: \.element.id) { i, p in
                            card(whoAmI: p, number: i + 1)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var dailyPuzzleMissing: Bool {
        pinnedFormat == nil || (format == .keep4 ? dailyKeep4 == nil : dailyWhoAmI == nil)
    }

    /// Today's ranked daily for the chosen sport — the same card Home shows, so the hub
    /// reads as "the daily, then everything else this format has".
    @ViewBuilder private var dailySection: some View {
        if format == .keep4, let p = dailyKeep4 {
            DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill", sport: p.sport,
                          title: p.theme, subtitle: "\(p.players.count) \(p.puzzleGrain().countNoun)",
                          scoring: p.scoringKind(), grain: p.puzzleGrain(),
                          completed: container.hasCompletedToday(puzzleID: p.id),
                          favoriteTeamMatch: container.favoriteTeams.team(for: p.sport)
                              .map(p.features(teamAbbr:)) ?? false,
                          ranked: true,
                          dateBadge: DailyGameCard.todayDateBadge) {
                activeDailyKeep4 = p
            }
            secondaryAction: { shareTarget = SharablePuzzle(keep4: p) }
        } else if format == .whoami, let p = dailyWhoAmI {
            DailyGameCard(formatName: "Who am I?", symbol: "questionmark.circle.fill", sport: p.sport,
                          title: String(localized: "Guess today's mystery player"),
                          subtitle: String(localized: "\(p.clues.count) clues"),
                          completed: container.hasCompletedToday(puzzleID: p.id),
                          typeColor: .voltFill, onTypeColor: .onVolt,
                          ranked: true,
                          dateBadge: DailyGameCard.todayDateBadge) {
                activeDailyWhoAmI = p
            }
            secondaryAction: { shareTarget = SharablePuzzle(whoAmI: p) }
        }
    }

    private var filteredKeep4: [Keep4Puzzle] {
        keep4.filter {
            BrowseFilters.matchesDecade($0, filter: decadeFilter) &&
                BrowseFilters.matchesGrain($0, filter: grainFilter) &&
                PuzzleSearch.matches(query: searchText, keep4: $0)
        }
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
                      completed: container.hasCompletedToday(puzzleID: p.id), typeColor: .voltFill, onTypeColor: .onVolt) {
            playArchive { activeWhoAmI = p }
        }
        secondaryAction: { shareTarget = SharablePuzzle(whoAmI: p) }
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
        if format == .keep4 {
            keep4 = await container.puzzles.allKeep4(for: sportFilter)
        } else {
            whoami = await container.puzzles.allWhoAmI(for: sportFilter)
        }
        if pinnedFormat != nil {
            if format == .keep4 {
                dailyKeep4 = await container.puzzles.keep4Puzzle(for: sportFilter, date: Date())
            } else {
                dailyWhoAmI = await container.puzzles.whoAmIPuzzle(for: sportFilter, date: Date())
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
