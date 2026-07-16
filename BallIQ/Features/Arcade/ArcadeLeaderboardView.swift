import SwiftUI

/// This week's arcade board for one game+sport (backlog #5) — the shared payoff view for
/// Over/Under and Grid, presented as a sheet off each result screen. Reads
/// `arcade_leaderboard` (top-50 + the caller's own ranked row) and renders the same
/// rank/avatar/name/value row idiom as `DailyDraftLeaderboardView` and the Leagues
/// standings, so all three competitive tables read as one family.
struct ArcadeLeaderboardView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @Environment(\.dismiss) private var dismiss

    let game: ArcadeLeaderboardRepository.Game
    let sport: Sport

    @State private var rows: [ArcadeLeaderboardRepository.Row] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    emptyState
                } else {
                    board
                }
            }
            .background(Color.appBackground)
            .navigationTitle(game.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private var emptyState: some View {
        EmptyStateView(symbol: "list.number",
                       title: "No scores yet",
                       message: container.isSignedIn
                           ? "Nobody's posted a run this week — yours can set the bar."
                           : "Sign in to put your runs on this week's board.")
    }

    private var board: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                VStack(spacing: 10) {
                    ForEach(rows) { row in boardRow(row) }
                }
                .heroReveal(0)
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("THIS WEEK'S BOARD").font(.label11).foregroundStyle(Color.onAccent.opacity(0.75))
                Text(sport.displayName).font(.heading).foregroundStyle(Color.onAccent)
            }
            Spacer()
            Image(systemName: "list.number").font(.system(size: 22)).foregroundStyle(Color.onAccent)
        }
        .padding(16)
        .blockCard(fill: .accentFill)
    }

    private func boardRow(_ row: ArcadeLeaderboardRepository.Row) -> some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.hero(18))
                .foregroundStyle(row.rank <= 3 ? Color.accentText : Color.textMuted)
                .frame(width: 28, alignment: .leading)
            AvatarView(avatar: row.avatar, size: 28, emojiFallback: nil)
            Text(row.displayName)
                .font(row.isMe ? .bodyStrong : .body14)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text("\(row.bestScore) PTS")
                .font(.statValue)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(12)
        .background(row.isMe ? Color.accentBg : Color.clear)
        .cardSurface()
    }

    private func load() async {
        defer { loaded = true }
        guard let board = container.arcadeBoard else { return }
        rows = await board.leaderboard(game: game, sport: sport)
    }
}

/// The result-screen entry point to this board — one shared row so Over/Under and Grid (and
/// any future arcade format) present the identical affordance. Before this existed, each
/// result screen hand-rolled its own button and they'd already drifted: Over/Under had this
/// full card row, Grid a bare capsule pill with no explainer (AGENTS.md §4).
struct ArcadeLeaderboardEntryRow: View {
    /// One line under the title saying which runs the board ranks, e.g.
    /// "THIS WEEK'S TOP OVER/UNDER RUNS".
    let caption: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.number")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leaderboard").font(.title).foregroundStyle(Color.textPrimary)
                    Text(caption).font(.label11).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .cardSurface()
        }
        .buttonStyle(PrimePressStyle())
    }
}
