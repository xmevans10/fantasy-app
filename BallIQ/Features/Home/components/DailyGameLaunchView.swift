import SwiftUI

/// Setup → fetch → play wrapper for the daily formats (Keep4/Cut4 and Who Am I?), which
/// need a concrete puzzle fetched for the chosen sport before their game view can exist.
/// The arcade formats (Draft & Spin, Over/Under, The Grid) own their setup phase inside
/// their game views; this wrapper gives the two daily formats the same setup-first flow.
struct DailyGameLaunchView: View {
    enum DailyFormat {
        case keep4, whoAmI

        var displayName: String { self == .keep4 ? "K4C4" : "Who am I?" }
    }

    let format: DailyFormat
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    @State private var sport: Sport = .nfl
    @State private var showingSetup = true
    @State private var loading = false
    @State private var keep4Puzzle: Keep4Puzzle?
    @State private var whoAmIPuzzle: WhoAmIPuzzle?

    var body: some View {
        Group {
            if let keep4Puzzle {
                Keep4GameView(puzzle: keep4Puzzle).environmentObject(container)
            } else if let whoAmIPuzzle {
                WhoAmIGameView(puzzle: whoAmIPuzzle).environmentObject(container)
            } else if showingSetup {
                GameSetupScreen(formatName: format.displayName,
                                title: "Pick your sport",
                                startLabel: "Play today's puzzle",
                                sport: $sport,
                                onStart: { Task { await launch() } },
                                onClose: { dismiss() }) { EmptyView() }
            } else if loading {
                ProgressView().tint(Color.accentText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(symbol: "calendar.badge.exclamationmark",
                              title: "No puzzle today",
                              message: "No \(sport.displayName) \(format.displayName) puzzle is live today — try another sport.",
                              actionTitle: "Close", action: { dismiss() })
            }
        }
        .background(Color.appBackground)
        .task { sport = container.sportFilter.sport ?? .nfl }
    }

    private func launch() async {
        showingSetup = false
        loading = true
        let filter = SportFilter(rawValue: sport.rawValue) ?? .all
        switch format {
        case .keep4: keep4Puzzle = await container.puzzles.keep4Puzzle(for: filter, date: Date())
        case .whoAmI: whoAmIPuzzle = await container.puzzles.whoAmIPuzzle(for: filter, date: Date())
        }
        loading = false
    }
}
