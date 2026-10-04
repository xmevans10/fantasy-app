import SwiftUI

struct TeamHubView: View {
    @EnvironmentObject private var container: RepositoryContainer
    let sport: Sport
    let teamAbbr: String
    @State private var boards: [Keep4Puzzle] = []
    @State private var loading = true
    @State private var identities: [TeamIdentity] = []
    @State private var activePuzzle: Keep4Puzzle?
    @State private var showPaywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TeamHubHeader(sport: sport, teamAbbr: teamAbbr,
                              subtitle: "One club. Eight seasons. Keep the best four.",
                              identity: identities.first { $0.abbr == teamAbbr })
                Text("TEAM COLLECTION").font(.label12).foregroundStyle(Color.textMuted)
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else if boards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No team-only boards available yet").font(.title)
                        Text("Your favorite is saved. This collection will show boards when all eight seasons belong to your club. You can keep playing the general daily games on Home.")
                            .font(.body14).foregroundStyle(Color.textMuted)
                        Button("Check again") { Task { await load() } }.font(.label12)
                    }
                    .padding(16).cardSurface()
                } else {
                    Text("\(boards.count) team-only boards · Career XP · Unranked")
                        .font(.body14).foregroundStyle(Color.textMuted)
                    ForEach(boards) { puzzle in
                        DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill",
                                      sport: sport, title: puzzle.theme,
                                      subtitle: "Eight seasons from \(teamAbbr)",
                                      completed: container.hasCompletedToday(puzzleID: puzzle.id)) {
                            if container.entitlements.canAccessArchive { activePuzzle = puzzle }
                            else { showPaywall = true }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .navigationTitle("Your team")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(sport.rawValue)|\(teamAbbr)") { await load() }
        .fullScreenCover(item: $activePuzzle) { puzzle in
            Keep4GameView(puzzle: puzzle, ranked: false).environmentObject(container)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(trigger: .archive).environmentObject(container)
        }
    }

    private func load() async {
        loading = true
        identities = await container.catalog.teamIdentities(for: sport)
        let pool = await container.puzzles.allKeep4(for: SportFilter(rawValue: sport.rawValue) ?? .all)
        guard !Task.isCancelled else { return }
        // Soccer abbreviation collisions cannot establish club identity without a league
        // on every player card. Until that contract exists, exclude ambiguous clubs.
        let matchingIdentities = identities
            .filter { $0.abbr.uppercased() == teamAbbr.uppercased() }
        let ambiguous = sport == .soccer && Set(matchingIdentities.map(\.league)).count != 1
        boards = ambiguous ? [] : pool.filter { $0.isExclusive(to: teamAbbr, sport: sport) }
        loading = false
    }
}
