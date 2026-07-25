import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: RepositoryContainer
    /// Root tab selection (0 Home…4 Profile) — the formats grid uses this to jump to the
    /// Versus tab, since Versus is a full tab/repository, not a sheet Home can present itself.
    @Binding var selectedTab: Int
    /// Today's daily K4C4/Who Am I? pick per sport, keyed as pages fill in — see
    /// `loadDaily(for:)`. A missing key means "not fetched yet", not "no puzzle"; `loadedSports`
    /// disambiguates that from a genuine empty result once the fetch resolves.
    @State private var keep4BySport: [Sport: DailyPick<Keep4Puzzle>] = [:]
    @State private var whoAmIBySport: [Sport: DailyPick<WhoAmIPuzzle>] = [:]
    @State private var loadedSports: Set<Sport> = []
    /// The sport page currently visible in the daily-games pager. Browsing only — swiping
    /// never writes back to `container.sportFilter` (2026-07-09 decision, see `body` below).
    @State private var dailyPage: Sport = .nfl
    @State private var activePuzzle: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?
    @State private var showBrowse = false
    @State private var showPaywall = false
    @State private var showOverUnder = false
    @State private var showDraftSpin = false
    @State private var showDailyDraft = false
    @State private var showGrid = false
    /// The K4C4/Who Am I? tiles open their format hub (daily + archive in one place,
    /// 2026-07-17 IA fix) — not just today's daily, which made the flashiest tiles the
    /// shallowest tap on the page.
    @State private var showKeep4Hub = false
    @State private var showWhoAmIHub = false
    @State private var shareTarget: SharablePuzzle?

    private let gridColumns = [GridItem(.flexible(), spacing: 12),
                               GridItem(.flexible(), spacing: 12)]

    /// Sport whose rating the rank widget shows (selected filter, else NFL).
    private var rankSport: Sport { container.sportFilter.sport ?? .nfl }

    /// nil when the puzzle hasn't loaded (or failed to) — kept distinct from `false` so a
    /// load failure never gets counted as "completed" by `HomeDailyLoop`. Tracks whichever
    /// sport's page is currently visible in the pager, not necessarily `container.sportFilter`.
    private var keep4CompletedToday: Bool? {
        keep4BySport[dailyPage].map { container.hasCompletedToday(puzzleID: $0.content.id) }
    }
    private var whoAmICompletedToday: Bool? {
        whoAmIBySport[dailyPage].map { container.hasCompletedToday(puzzleID: $0.content.id) }
    }
    private var bothDailiesComplete: Bool {
        HomeDailyLoop.bothDailiesComplete(keep4Completed: keep4CompletedToday, whoAmICompleted: whoAmICompletedToday)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // No sport chips here anymore (2026-07-09): sport is chosen per-game on
                    // each format's own setup screen, which writes the choice back to
                    // `container.sportFilter` so these daily previews follow the last pick.
                    streakRow.heroReveal(0)

                    section("Today's daily games") {
                        VStack(spacing: 14) {
                            if bothDailiesComplete {
                                // Sells tomorrow instead of leaving the section reading as
                                // "two finished cards and nothing else to do" — the arcade
                                // formats are still fair game today even once the ranked
                                // dailies are done.
                                DailyLoopCountdownCard(streak: container.streak,
                                                       arcadeFormats: GameFormat.arcade,
                                                       launch: launch,
                                                       launchDailyDraft: { showDailyDraft = true })
                            }
                            // Still visible (tapping either reopens today's result/recap, same
                            // as before) but visually secondary once the countdown card above
                            // is doing the selling — a dimmed "DONE" pair reads as evidence of
                            // completion, not the next thing to do. Swiping browses every
                            // sport's pair (2026-07-20); it never writes `container.sportFilter`
                            // (2026-07-09: sport is chosen per-game on each format's own setup
                            // screen, not globally) — that's still the only writer.
                            DailyGamesPager(sports: Sport.allCases, selection: $dailyPage) { sport in
                                dailyCardStack(for: sport)
                            }
                            .opacity(bothDailiesComplete ? 0.6 : 1)
                        }
                    }
                    .heroReveal(1)

                    // Directly beneath the daily cards that feed it — the rank used to sit at
                    // the very bottom of the page, disconnected from the ranked games above
                    // (user feedback 2026-07-17: "ranked puzzles are not intuitively placed").
                    section("Your rank") {
                        RankWidget(sport: rankSport, rating: container.rating(for: rankSport))
                    }
                    .heroReveal(2)

                    Button {
                        if container.entitlements.canAccessArchive { showBrowse = true }
                        else { showPaywall = true }
                    } label: { browseRow }
                        .buttonStyle(PrimePressStyle())
                        .heroReveal(3)

                    section("Game formats") {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(GameFormat.all) { format in
                                FormatGridItem(format: format) { launch(format) }
                            }
                        }
                    }
                    .heroReveal(4)
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("")
            .navigationDestination(isPresented: $showBrowse) {
                BrowseView().environmentObject(container)
            }
            .fullScreenCover(item: $activePuzzle) { puzzle in
                Keep4GameView(puzzle: puzzle).environmentObject(container)
            }
            .fullScreenCover(item: $activeWhoAmI) { puzzle in
                WhoAmIGameView(puzzle: puzzle).environmentObject(container)
            }
            .fullScreenCover(isPresented: $showOverUnder) {
                OverUnderGameView().environmentObject(container)
            }
            .fullScreenCover(isPresented: $showDraftSpin) {
                DraftSpinView().environmentObject(container)
            }
            .fullScreenCover(isPresented: $showDailyDraft) {
                DraftSpinView(startInDailyDraft: true).environmentObject(container)
            }
            .fullScreenCover(isPresented: $showGrid) {
                GridGameView().environmentObject(container)
            }
            .navigationDestination(isPresented: $showKeep4Hub) {
                BrowseView(pinnedFormat: .keep4).environmentObject(container)
            }
            .navigationDestination(isPresented: $showWhoAmIHub) {
                BrowseView(pinnedFormat: .whoami).environmentObject(container)
            }
            .sheet(item: $shareTarget) { target in
                PuzzleShareSheet(puzzle: target, surface: "puzzle_home")
                    .environmentObject(container)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView().environmentObject(container)
            }
            .task(id: container.sportFilter) { await loadDaily() }
        }
    }

    /// Current streak, shown inline in the page body (not a nav-bar icon — that read as a
    /// broken logo on other tabs since each tab's toolbar item meant something different).
    private var streakRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(container.streak > 0 ? Color.warningFill : Color.textMuted)
            Text(container.streak == 1 ? "1 day streak" : "\(container.streak) day streak")
                .font(.label12)
                .foregroundStyle(Color.textPrimary)
        }
    }

    /// Entry point to the full archive (every daily puzzle, not just today's). Pro-gated —
    /// tapping while locked opens the paywall instead (see `HomeView.body`'s Button action).
    private var browseRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse all puzzles").font(.title).foregroundStyle(Color.textPrimary)
                Text("REPLAY THE FULL ARCHIVE").font(.label11).foregroundStyle(Color.textMuted)
            }
            Spacer()
            if !container.entitlements.canAccessArchive {
                Text("PRO")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.proText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.proBg)
                    .clipShape(Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private func launch(_ format: GameFormat) {
        switch format.id {
        case "keep4": showKeep4Hub = true
        case "whoami": showWhoAmIHub = true
        case "versus": selectedTab = 2
        case "overunder": showOverUnder = true
        case "draft": showDraftSpin = true
        case "grid":
            if container.entitlements.canPlayGrid() { showGrid = true } else { showPaywall = true }
        default: break
        }
    }

    /// Lands the pager on the last-played sport and makes sure that page's dailies are ready
    /// before any debug/screenshot auto-open runs. Every other sport's page lazy-loads itself
    /// via `dailyCardStack(for:)`'s own `.task` once the pager actually mounts it (a swipe, or
    /// whatever neighbor pages `DailyGamesPager`'s scroll view keeps warm on its own) —
    /// `loadDaily(for:)` is idempotent via `loadedSports`, so this never double-fetches the
    /// initial sport.
    private func loadDaily() async {
        let initial = container.sportFilter.sport ?? .nfl
        dailyPage = initial
        // Warm the arcade pool for the sport the player is most likely to spin next (their
        // last-played sport) while they're still looking at Home — Draft & Spin and
        // Over/Under then open with a hot cache instead of a first-fetch spinner.
        container.catalog.prefetchDraftSpinSample(for: initial)
        await loadDaily(for: initial)
        if DebugLaunch.autoOpenWhoAmI, activeWhoAmI == nil {
            activeWhoAmI = whoAmIBySport[initial]?.content
        } else if DebugLaunch.autoOpenGame, activePuzzle == nil {
            activePuzzle = keep4BySport[initial]?.content
        } else if DebugLaunch.autoOpenBrowse {
            showBrowse = true
        } else if DebugLaunch.autoOpenOverUnder {
            showOverUnder = true
        } else if DebugLaunch.autoOpenDailyDraft {
            showDailyDraft = true
        } else if DebugLaunch.autoOpenDraftSpin {
            showDraftSpin = true
        } else if DebugLaunch.autoOpenGrid {
            showGrid = true
        }
    }

    /// Fetches one sport's daily pair exactly once per Home session — `RemotePuzzleRepository`
    /// disk-caches per (format, sport) underneath this, so a first-time fetch for a sport the
    /// player swipes to is the only real network hit; every page after that is instant.
    private func loadDaily(for sport: Sport) async {
        guard !loadedSports.contains(sport) else { return }
        loadedSports.insert(sport)
        let filter = SportFilter(rawValue: sport.rawValue) ?? .all
        // Independent reads — starting them together removes an avoidable round trip.
        async let keep4Task = container.puzzles.keep4Puzzle(for: filter, date: Date())
        async let whoAmITask = container.puzzles.whoAmIPuzzle(for: filter, date: Date())
        keep4BySport[sport] = await keep4Task
        whoAmIBySport[sport] = await whoAmITask
    }

    /// One pager page: that sport's K4C4 + Who Am I? daily cards, stacked exactly like the
    /// former single-sport layout. Its own `.task(id:)` is the lazy-load trigger for every
    /// sport besides the initial one (see `loadDaily()`'s doc comment).
    @ViewBuilder
    private func dailyCardStack(for sport: Sport) -> some View {
        VStack(spacing: 14) {
            if let pick = keep4BySport[sport] {
                let puzzle = pick.content
                DailyGameCard(formatName: "K4C4",
                              symbol: "rectangle.stack.fill",
                              sport: puzzle.sport,
                              title: puzzle.theme,
                              subtitle: "\(puzzle.players.count) \(puzzle.puzzleGrain().countNoun)",
                              scoring: puzzle.scoringKind(),
                              grain: puzzle.puzzleGrain(),
                              completed: container.hasCompletedToday(puzzleID: puzzle.id),
                              favoriteTeamMatch: container.favoriteTeams.team(for: puzzle.sport)
                                  .map(puzzle.features(teamAbbr:)) ?? false,
                              ranked: true,
                              dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                    // The daily card IS the puzzle — it opens directly (explicit feedback: no
                    // intermediate setup screen when the puzzle is already loaded and shown on
                    // the card). The formats grid below still routes through setup, where
                    // picking a sport is the point.
                    activePuzzle = puzzle
                }
                secondaryAction: { shareTarget = SharablePuzzle(keep4: puzzle) }
            } else {
                dailyCardPlaceholder(loaded: loadedSports.contains(sport))
            }
            if let pick = whoAmIBySport[sport] {
                let puzzle = pick.content
                DailyGameCard(formatName: "Who am I?",
                              symbol: "questionmark.circle.fill",
                              sport: puzzle.sport,
                              title: String(localized: "Guess today's mystery player"),
                              subtitle: String(localized: "\(puzzle.clues.count) clues"),
                              completed: container.hasCompletedToday(puzzleID: puzzle.id),
                              typeColor: .voltFill, onTypeColor: .onVolt,
                              ranked: true,
                              dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                    activeWhoAmI = puzzle
                }
                secondaryAction: { shareTarget = SharablePuzzle(whoAmI: puzzle) }
            } else {
                dailyCardPlaceholder(loaded: loadedSports.contains(sport))
            }
        }
        .task(id: sport) { await loadDaily(for: sport) }
    }

    /// Fills a daily card's spot while its sport's page is still loading, so the pager doesn't
    /// visibly collapse/reflow mid-swipe. `loaded` true with no puzzle is a genuine empty
    /// result (no spinner — there's nothing coming), matching the pre-pager single-sport
    /// behavior of simply omitting the card.
    @ViewBuilder
    private func dailyCardPlaceholder(loaded: Bool) -> some View {
        if !loaded {
            HStack {
                Spacer()
                ProgressView().tint(.accentFill)
                Spacer()
            }
            .frame(height: 96)
            .cardSurface()
        }
    }

    @ViewBuilder
    // LocalizedStringKey so the three literal section titles extract into
    // Localizable.xcstrings — same pattern as EmptyStateView/GameSetupScreen.
    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Broadcast lower-third chip instead of bare ink text (2026-07-17 "too much
            // white" pass) — shared with the format hubs via `LowerThirdHeader`.
            LowerThirdHeader(title: title)
            content()
        }
    }
}

#Preview {
    HomeView(selectedTab: .constant(0)).environmentObject(RepositoryContainer.make())
}
