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
    @State private var shareTarget: SharablePuzzle?

    private let gridColumns = [GridItem(.flexible(), spacing: 12),
                               GridItem(.flexible(), spacing: 12)]

    /// Sport whose rating the rank widget shows (selected filter, else NFL).
    private var rankSport: Sport { container.sportFilter.sport ?? .nfl }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SportFilterBar(selection: $container.sportFilter)
                        .heroReveal(0)

                    streakRow

                    section("Today's daily games") {
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
                    }
                    .heroReveal(1)

                    Button { showBrowse = true } label: { browseRow }
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
            .sheet(item: $shareTarget) { target in
                PuzzleShareSheet(puzzle: target, surface: "puzzle_home")
                    .environmentObject(container)
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

    /// Entry point to the full archive (every daily puzzle, not just today's).
    private var browseRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse all puzzles").font(.title).foregroundStyle(Color.textPrimary)
                Text("REPLAY THE FULL ARCHIVE").font(.label11).foregroundStyle(Color.textMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private func launch(_ format: GameFormat) {
        switch format.id {
        case "keep4": activePuzzle = keep4
        case "whoami": activeWhoAmI = whoami
        case "versus": selectedTab = 2
        default: break
        }
    }

    private func loadDaily() async {
        keep4 = await container.puzzles.keep4Puzzle(for: container.sportFilter, date: Date())
        whoami = await container.puzzles.whoAmIPuzzle(for: container.sportFilter, date: Date())
        if DebugLaunch.autoOpenWhoAmI, activeWhoAmI == nil {
            activeWhoAmI = whoami
        } else if DebugLaunch.autoOpenGame, activePuzzle == nil {
            activePuzzle = keep4
        } else if DebugLaunch.autoOpenBrowse {
            showBrowse = true
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
