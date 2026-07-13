import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: RepositoryContainer
    /// Root tab selection (0 Home…4 Profile) — the formats grid uses this to jump to the
    /// Versus tab, since Versus is a full tab/repository, not a sheet Home can present itself.
    @Binding var selectedTab: Int
    @State private var keep4: Keep4Puzzle?
    @State private var whoami: WhoAmIPuzzle?
    @State private var activePuzzle: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?
    @State private var showBrowse = false
    @State private var showPaywall = false
    @State private var showOverUnder = false
    @State private var showDraftSpin = false
    @State private var showGrid = false
    @State private var showKeep4Launch = false
    @State private var showWhoAmILaunch = false
    @State private var shareTarget: SharablePuzzle?

    private let gridColumns = [GridItem(.flexible(), spacing: 12),
                               GridItem(.flexible(), spacing: 12)]

    /// Sport whose rating the rank widget shows (selected filter, else NFL).
    private var rankSport: Sport { container.sportFilter.sport ?? .nfl }

    /// nil when the puzzle hasn't loaded (or failed to) — kept distinct from `false` so a
    /// load failure never gets counted as "completed" by `HomeDailyLoop`.
    private var keep4CompletedToday: Bool? { keep4.map { container.hasCompletedToday(puzzleID: $0.id) } }
    private var whoAmICompletedToday: Bool? { whoami.map { container.hasCompletedToday(puzzleID: $0.id) } }
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
                                                       launch: launch)
                            }
                            // Still visible (tapping either reopens today's result/recap, same
                            // as before) but visually secondary once the countdown card above
                            // is doing the selling — a dimmed "DONE" pair reads as evidence of
                            // completion, not the next thing to do.
                            VStack(spacing: 14) {
                                if let puzzle = keep4 {
                                    DailyGameCard(formatName: "K4C4",
                                                  symbol: "rectangle.stack.fill",
                                                  sport: puzzle.sport,
                                                  title: puzzle.theme,
                                                  subtitle: "\(puzzle.players.count) \(puzzle.puzzleGrain().countNoun)",
                                                  scoring: puzzle.scoringKind(),
                                                  grain: puzzle.puzzleGrain(),
                                                  completed: container.hasCompletedToday(puzzleID: puzzle.id),
                                                  favoriteTeamMatch: container.favoriteTeams.team(for: puzzle.sport)
                                                      .map(puzzle.features(teamAbbr:)) ?? false) {
                                        // The daily card IS the puzzle — it opens directly
                                        // (explicit feedback: no intermediate setup screen when
                                        // the puzzle is already loaded and shown on the card).
                                        // The formats grid below still routes through setup,
                                        // where picking a sport is the point.
                                        activePuzzle = puzzle
                                    }
                                    secondaryAction: { shareTarget = SharablePuzzle(keep4: puzzle) }
                                }
                                if let puzzle = whoami {
                                    DailyGameCard(formatName: "Who am I?",
                                                  symbol: "questionmark.circle.fill",
                                                  sport: puzzle.sport,
                                                  title: "Guess today's mystery player",
                                                  subtitle: "\(puzzle.clues.count) clues",
                                                  completed: container.hasCompletedToday(puzzleID: puzzle.id),
                                                  typeColor: .voltFill, onTypeColor: .onVolt) {
                                        activeWhoAmI = puzzle
                                    }
                                    secondaryAction: { shareTarget = SharablePuzzle(whoAmI: puzzle) }
                                }
                            }
                            .opacity(bothDailiesComplete ? 0.6 : 1)
                        }
                    }
                    .heroReveal(1)

                    Button {
                        if container.entitlements.canAccessArchive { showBrowse = true }
                        else { showPaywall = true }
                    } label: { browseRow }
                        .buttonStyle(PrimePressStyle())
                        .heroReveal(2)

                    section("Game formats") {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(GameFormat.all) { format in
                                FormatGridItem(format: format) { launch(format) }
                            }
                        }
                    }
                    .heroReveal(3)

                    section("Your rank") {
                        RankWidget(sport: rankSport, rating: container.rating(for: rankSport))
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
            .fullScreenCover(isPresented: $showGrid) {
                GridGameView().environmentObject(container)
            }
            .fullScreenCover(isPresented: $showKeep4Launch) {
                DailyGameLaunchView(format: .keep4).environmentObject(container)
            }
            .fullScreenCover(isPresented: $showWhoAmILaunch) {
                DailyGameLaunchView(format: .whoAmI).environmentObject(container)
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
        case "keep4": showKeep4Launch = true
        case "whoami": showWhoAmILaunch = true
        case "versus": selectedTab = 2
        case "overunder": showOverUnder = true
        case "draft": showDraftSpin = true
        case "grid":
            if container.entitlements.canPlayGrid() { showGrid = true } else { showPaywall = true }
        default: break
        }
    }

    private func loadDaily() async {
        // These are independent reads. Starting them together removes an avoidable network
        // round trip from Home's first meaningful paint.
        async let keep4Task = container.puzzles.keep4Puzzle(for: container.sportFilter, date: Date())
        async let whoAmITask = container.puzzles.whoAmIPuzzle(for: container.sportFilter, date: Date())
        // Warm the arcade pool for the sport the player is most likely to spin next (their
        // last-played sport) while they're still looking at Home — Draft & Spin and
        // Over/Under then open with a hot cache instead of a first-fetch spinner.
        container.catalog.prefetchDraftSpinSample(for: container.sportFilter.sport ?? .nfl)
        keep4 = await keep4Task
        whoami = await whoAmITask
        if DebugLaunch.autoOpenWhoAmI, activeWhoAmI == nil {
            activeWhoAmI = whoami
        } else if DebugLaunch.autoOpenGame, activePuzzle == nil {
            activePuzzle = keep4
        } else if DebugLaunch.autoOpenBrowse {
            showBrowse = true
        } else if DebugLaunch.autoOpenOverUnder {
            showOverUnder = true
        } else if DebugLaunch.autoOpenDraftSpin {
            showDraftSpin = true
        } else if DebugLaunch.autoOpenGrid {
            showGrid = true
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.heading)
                .textCase(.uppercase)
                .foregroundStyle(Color.textPrimary)
            content()
        }
    }
}

#Preview {
    HomeView(selectedTab: .constant(0)).environmentObject(RepositoryContainer.make())
}
