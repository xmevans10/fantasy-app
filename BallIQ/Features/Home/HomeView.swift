import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @State private var keep4: Keep4Puzzle?
    @State private var whoami: WhoAmIPuzzle?
    @State private var activePuzzle: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?

    private let gridColumns = [GridItem(.flexible(), spacing: 12),
                               GridItem(.flexible(), spacing: 12)]

    /// Sport whose rating the rank widget shows (selected filter, else NFL).
    private var rankSport: Sport { container.sportFilter.sport ?? .nfl }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    StreakBar(streak: container.streak, playedToday: container.hasPlayedToday())
                        .heroReveal(0)

                    SportFilterBar(selection: $container.sportFilter)
                        .heroReveal(1)

                    section("Today's daily games") {
                        VStack(spacing: 14) {
                            if let puzzle = keep4 {
                                DailyGameCard(formatName: "K4C4",
                                              symbol: "rectangle.stack.fill",
                                              sport: puzzle.sport,
                                              title: puzzle.theme,
                                              subtitle: "\(puzzle.players.count) seasons",
                                              completed: container.hasPlayedToday(),
                                              accent: .accentFill, onAccent: .onAccent) {
                                    activePuzzle = puzzle
                                }
                            }
                            if let puzzle = whoami {
                                DailyGameCard(formatName: "Who am I?",
                                              symbol: "questionmark.circle.fill",
                                              sport: puzzle.sport,
                                              title: "Guess today's mystery player",
                                              subtitle: "\(puzzle.clues.count) clues",
                                              completed: container.hasPlayedToday(),
                                              accent: .voltFill, onAccent: .onVolt) {
                                    activeWhoAmI = puzzle
                                }
                            }
                        }
                    }
                    .heroReveal(2)

                    NavigationLink { BrowseView().environmentObject(container) } label: { browseRow }
                        .heroReveal(3)

                    section("Game formats") {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(GameFormat.all) { format in
                                FormatGridItem(format: format) { launch(format) }
                            }
                        }
                    }
                    .heroReveal(4)

                    section("Your rank") {
                        RankWidget(rating: container.rating(for: rankSport))
                    }
                    .heroReveal(5)
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Wordmark() }
            }
            .fullScreenCover(item: $activePuzzle) { puzzle in
                Keep4GameView(puzzle: puzzle).environmentObject(container)
            }
            .fullScreenCover(item: $activeWhoAmI) { puzzle in
                WhoAmIGameView(puzzle: puzzle).environmentObject(container)
            }
            .task(id: container.sportFilter) { await loadDaily() }
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
    HomeView().environmentObject(RepositoryContainer.make())
}
