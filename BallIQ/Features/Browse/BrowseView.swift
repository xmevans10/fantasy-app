import SwiftUI

/// Archive of every daily puzzle (not just today's). Playing from here is **unranked**
/// (XP only) — replaying past dailies shouldn't move the competitive rating. Mirrors the
/// Community browse layout; reads the full pool via `PuzzleRepository.all*`.
struct BrowseView: View {
    @EnvironmentObject private var container: RepositoryContainer

    @State private var format: BrowseFormat = .keep4
    @State private var sportFilter: SportFilter = .all
    @State private var keep4: [Keep4Puzzle] = []
    @State private var whoami: [WhoAmIPuzzle] = []
    @State private var loading = false

    @State private var activeKeep4: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?

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
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshKey) { await load() }
        .fullScreenCover(item: $activeKeep4) { p in
            Keep4GameView(puzzle: p, ranked: false).environmentObject(container)
        }
        .fullScreenCover(item: $activeWhoAmI) { p in
            WhoAmIGameView(puzzle: p, ranked: false).environmentObject(container)
        }
    }

    private var refreshKey: String { "\(format.rawValue)-\(sportFilter.rawValue)" }
    private var currentEmpty: Bool { format == .keep4 ? keep4.isEmpty : whoami.isEmpty }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Format", selection: $format) {
                ForEach(BrowseFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                ForEach(SportFilter.allCases) { f in
                    pill(f.title, active: sportFilter == f) { sportFilter = f }
                }
                Spacer()
            }
        }
        .padding(16)
    }

    private func pill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased()).font(.label12)
                .foregroundStyle(active ? Color.onAccent : Color.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(active ? Color.accentFill : Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if loading && currentEmpty {
            Spacer(); ProgressView().tint(.accentFill); Spacer()
        } else if currentEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if format == .keep4 {
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

    /// Themes repeat across many distinct puzzles, so number duplicates ("… #2") to tell them apart.
    private var numberedKeep4: [(puzzle: Keep4Puzzle, title: String)] {
        let totals = Dictionary(grouping: keep4, by: \.theme).mapValues(\.count)
        var seen: [String: Int] = [:]
        return keep4.map { p in
            seen[p.theme, default: 0] += 1
            let title = (totals[p.theme] ?? 1) > 1 ? "\(p.theme) #\(seen[p.theme]!)" : p.theme
            return (p, title)
        }
    }

    private func card(keep4 p: Keep4Puzzle, title: String) -> some View {
        DailyGameCard(formatName: "K4C4", symbol: p.sport.symbol, sport: p.sport,
                      title: title, subtitle: "\(p.players.count) seasons · archive",
                      completed: false, accent: .accentFill, onAccent: .onAccent) {
            activeKeep4 = p
        }
    }

    /// Who Am I? has no title (revealing one would spoil the answer) — show a neutral numbered label.
    private func card(whoAmI p: WhoAmIPuzzle, number: Int) -> some View {
        DailyGameCard(formatName: "Who am I?", symbol: p.sport.symbol, sport: p.sport,
                      title: "Mystery player #\(number)", subtitle: "\(p.clues.count) clues · archive",
                      completed: false, accent: .voltFill, onAccent: .onVolt) {
            activeWhoAmI = p
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray.full")
                .font(.system(size: 40)).foregroundStyle(Color.textMuted)
            Text("Nothing here yet").font(.heading).foregroundStyle(Color.textPrimary)
            Text("Daily puzzles will fill this archive.")
                .font(.body14).foregroundStyle(Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
    }
}
