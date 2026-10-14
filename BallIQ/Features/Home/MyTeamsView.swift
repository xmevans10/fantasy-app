import SwiftUI

/// Existing saved favorites drive the switcher; only published inventory is promoted.
struct MyTeamsView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @State private var sport: Sport = .nfl
    @State private var picking = false
    @State private var boards: [TeamPuzzle] = []
    @State private var loading = true
    @State private var failed = false
    @State private var active: TeamPuzzle?
    @State private var paywall = false
    @State private var opened = false
    private var team: String? { container.favoriteTeams.team(for: sport) }
    private var selectedKey: String { "\(sport.rawValue):\(team ?? "")" }
    private var featured: TeamPuzzle? {
        boards.first { !container.teamCompletedIDs.contains($0.id) && ($0.isStarter || container.entitlements.canAccessArchive) }
            ?? boards.first { $0.isStarter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MY TEAMS").font(.label12)
                Spacer()
                Menu {
                    ForEach(Sport.allCases.filter(\.hasTeams)) { value in
                        Button(value.displayName) { sport = value }
                    }
                } label: { Label(sport.displayName, systemImage: "chevron.down").font(.label12) }
                Button { picking = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Choose your team")
            }
            if team == nil {
                Button { picking = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "star.fill").font(.title)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("YOUR TEAM. YOUR GAME.").font(.title)
                            Text("Choose a favorite. Start with our Saints collection.").font(.body14)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                    }.foregroundStyle(Color.textPrimary).padding(16).cardSurface()
                }.buttonStyle(PrimePressStyle())
            } else if loading {
                ProgressView("Finding your team's games…").frame(maxWidth: .infinity).padding()
            } else if let featured {
                Button { open(featured) } label: {
                    TeamPuzzleHero(board: featured, completed: container.teamCompletedIDs.contains(featured.id))
                }.buttonStyle(PrimePressStyle())
                NavigationLink {
                    MyTeamHubView(sport: sport, team: team ?? "", initialBoards: boards)
                } label: {
                    HStack {
                        Text("Explore your team").font(.label12)
                        Spacer()
                        Text("\(boards.count) games").font(.label11)
                        Image(systemName: "arrow.right")
                    }.foregroundStyle(Color.textPrimary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failed ? "Your team couldn't load" : "Your favorite is saved").font(.title)
                    Text(failed ? "Try again, or play today's games below." : "Team games are starting with New Orleans. Today's general games are ready below.").font(.body14).foregroundStyle(Color.textMuted)
                    if failed { Button("Try again") { Task { await load() } }.font(.label12) }
                    else { Button("Try the Saints collection") { sport = .nfl; save("NO") }.font(.label12) }
                }.padding(16).cardSurface()
            }
        }
        .task(id: selectedKey) { await load() }
        .onAppear {
            if !opened {
                opened = true
                if let favorite = Sport.allCases.first(where: { $0.hasTeams && container.favoriteTeams.team(for: $0) != nil }) { sport = favorite }
            }
        }
        .sheet(isPresented: $picking) {
            TeamPicker(selection: Binding(get: { team }, set: { save($0) }), sport: sport,
                       fallbackAbbrs: container.catalog.teams(for: sport))
        }
        .sheet(isPresented: $paywall) { PaywallView(trigger: .archive).environmentObject(container) }
        .fullScreenCover(item: $active, onDismiss: { Task { await load() } }) { board in
            TeamPuzzleSession(board: board, inventory: boards).environmentObject(container)
        }
    }
    private func save(_ value: String?) {
        var favorites = container.favoriteTeams; favorites.setTeam(value, for: sport)
        Task { await container.saveFavoriteTeams(favorites) }
    }
    private func open(_ board: TeamPuzzle) {
        if board.isStarter || container.entitlements.canAccessArchive { active = board }
        else { paywall = true }
    }
    private func load() async {
        let key = selectedKey
        loading = true; failed = false; boards = []
        guard let team else { loading = false; return }
        do {
            let result = try await container.teamGames.load(sport: sport, team: team)
            guard !Task.isCancelled, selectedKey == key else { return }
            boards = result
            if !boards.isEmpty { container.track(.teamViewed, ["screen": "my_teams", "team": team, "sport": sport.rawValue]) }
        } catch { if !Task.isCancelled { failed = true } }
        if selectedKey == key { loading = false }
    }
}

struct TeamPuzzleHero: View {
    let board: TeamPuzzle
    var completed = false
    private var palette: TeamPalette { TeamColors.palette(sport: .nfl, abbr: board.teamAbbr) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TeamLogoBadge(sport: .nfl, teamAbbr: board.teamAbbr, tint: palette.onPrimary, size: 34)
                Text("NEW ORLEANS SAINTS").font(.label12)
                Spacer(minLength: 0)
                if board.isStarter { Text("FREE STARTER").font(.label11) }
            }
            Text(board.content.theme).font(.heading).fixedSize(horizontal: false, vertical: true)
            Text("K4C4 · Eight real seasons. Keep the best four.").font(.body14)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(completed ? "Play again" : "Play now", systemImage: completed ? "arrow.clockwise" : "play.fill").font(.label12)
                Spacer()
                Text(completed ? "Completed" : "Career XP · Unranked").font(.label11)
            }
        }.foregroundStyle(palette.onPrimary).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .blockCard(fill: palette.primary)
    }
}

struct MyTeamHubView: View {
    @EnvironmentObject private var container: RepositoryContainer
    let sport: Sport
    let team: String
    var initialBoards: [TeamPuzzle] = []
    @State private var boards: [TeamPuzzle] = []
    @State private var active: TeamPuzzle?
    @State private var paywall = false
    @State private var failed = false
    private var completed: [TeamPuzzle] { boards.filter { container.teamCompletedIDs.contains($0.id) } }
    private var next: TeamPuzzle? { boards.first { !container.teamCompletedIDs.contains($0.id) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(team == "NO" ? "NEW ORLEANS. ALL YOURS." : "YOUR TEAM. YOUR GAME.").font(.heading)
                Text("\(completed.count) of \(boards.count) games completed").font(.body14).foregroundStyle(Color.textMuted)
                if let next {
                    Text("PLAY NEXT").font(.label12)
                    Button { open(next) } label: { TeamPuzzleHero(board: next) }.buttonStyle(PrimePressStyle())
                }
                shelf("CLUB ICONS", key: "icons")
                shelf("THROUGH THE YEARS", key: "history")
                shelf("DEEP CUTS", key: "deep_cuts")
                if !completed.isEmpty {
                    Text("COMPLETED").font(.label12)
                    ForEach(completed) { row($0, replay: true) }
                }
                if failed {
                    Text("Couldn't refresh your collection. Your saved games are still available.").font(.body14)
                    Button("Try again") { Task { await load() } }
                }
                CareerProgressCard(xp: container.xp, compact: true)
            }.padding(16)
        }.paperGround().navigationTitle(team == "NO" ? "Your Saints" : "Your team")
            .navigationBarTitleDisplayMode(.inline)
            .task { boards = initialBoards; await load() }
            .refreshable { await load() }
            .sheet(isPresented: $paywall) { PaywallView(trigger: .archive).environmentObject(container) }
            .fullScreenCover(item: $active, onDismiss: { Task { await load() } }) { board in
                TeamPuzzleSession(board: board, inventory: boards).environmentObject(container)
            }
    }
    @ViewBuilder private func shelf(_ title: String, key: String) -> some View {
        let values = boards.filter { $0.shelf == key && !container.teamCompletedIDs.contains($0.id) }
        if !values.isEmpty {
            Text(title).font(.label12)
            ForEach(values) { row($0) }
        }
    }
    private func row(_ board: TeamPuzzle, replay: Bool = false) -> some View {
        Button { open(board) } label: {
            HStack(spacing: 12) {
                Image(systemName: replay ? "checkmark.circle.fill" : "rectangle.stack.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text(board.content.theme).font(.title).fixedSize(horizontal: false, vertical: true)
                    Text(replay ? "Play again · No repeat XP" : board.isStarter ? "K4C4 · Free starter" : "K4C4 · Pro collection").font(.label11).foregroundStyle(Color.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: board.isStarter || container.entitlements.canAccessArchive ? "chevron.right" : "lock.fill")
            }.foregroundStyle(Color.textPrimary).padding(16).cardSurface()
        }.buttonStyle(PrimePressStyle())
    }
    private func open(_ board: TeamPuzzle) {
        if board.isStarter || container.entitlements.canAccessArchive { active = board }
        else { paywall = true }
    }
    private func load() async {
        failed = false
        await container.settlePendingTeamGames()
        do { boards = try await container.teamGames.load(sport: sport, team: team) }
        catch { failed = true }
    }
}

/// Reuses the native game and result screen, then offers a different team puzzle.
struct TeamPuzzleSession: View {
    @EnvironmentObject private var container: RepositoryContainer
    let board: TeamPuzzle
    let inventory: [TeamPuzzle]
    @State private var current: TeamPuzzle?
    @State private var paywall = false
    private var playing: TeamPuzzle { current ?? board }
    private var next: TeamPuzzle? {
        inventory.first { $0.id != playing.id && !container.teamCompletedIDs.contains($0.id) }
    }
    var body: some View {
        Keep4GameView(puzzle: playing.content, ranked: false)
            .id(playing.id)
            .environment(\.teamPlayNext, next == nil ? nil : {
                guard let next else { return }
                if next.isStarter || container.entitlements.canAccessArchive { current = next }
                else { paywall = true }
            })
            .sheet(isPresented: $paywall) { PaywallView(trigger: .archive).environmentObject(container) }
            .onChange(of: playing.id, initial: true) { _, _ in
                container.track(.teamPuzzleStarted, ["puzzle_id": playing.id, "team": playing.teamAbbr])
            }
    }
}

private struct TeamPlayNextKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var teamPlayNext: (() -> Void)? {
        get { self[TeamPlayNextKey.self] }
        set { self[TeamPlayNextKey.self] = newValue }
    }
}
