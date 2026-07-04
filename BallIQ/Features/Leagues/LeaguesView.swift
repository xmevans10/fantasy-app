import SwiftUI

struct LeaguesView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var season: Season?
    @State private var standings: [CohortStandingRow] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    signInPrompt
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if standings.isEmpty {
                    noLeagueYet
                } else {
                    standingsList
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Leagues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Wordmark() } }
        }
        .task { await load() }
    }

    private var signInPrompt: some View {
        EmptyStateView(symbol: "trophy.fill",
                       title: "Leagues",
                       message: "Sign in to join a weekly league — climb the standings to promote.")
    }

    private var noLeagueYet: some View {
        EmptyStateView(symbol: "hourglass",
                       title: "Your league forms soon",
                       message: "Leagues are assigned at the start of each week. Play a few ranked puzzles and check back.")
    }

    private var standingsList: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let season { countdownCard(season).heroReveal(0) }
                VStack(spacing: 10) {
                    ForEach(standings) { row in standingRow(row) }
                }
                .heroReveal(1)
            }
            .padding(16)
        }
    }

    private func countdownCard(_ season: Season) -> some View {
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: season.endsAt).day ?? 0)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SEASON ENDS").font(.label11).foregroundStyle(Color.onAccent.opacity(0.75))
                Text(days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s")")
                    .font(.heading).foregroundStyle(Color.onAccent)
            }
            Spacer()
            Image(systemName: "calendar").font(.system(size: 22)).foregroundStyle(Color.onAccent)
        }
        .padding(16)
        .blockCard(fill: .accentFill)
    }

    private func standingRow(_ row: CohortStandingRow) -> some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.hero(18))
                .foregroundStyle(zoneColor(row.zone))
                .frame(width: 28, alignment: .leading)
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.textMuted)
            Text(row.displayName)
                .font(row.isMe ? .bodyStrong : .body14)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text("\(row.weeklyXp) XP")
                .font(.statValue)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(12)
        .background(row.isMe ? Color.accentBg : Color.clear)
        .cardSurface()
        .overlay(alignment: .leading) {
            if row.zone != .hold {
                Rectangle().fill(zoneColor(row.zone)).frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
    }

    private func zoneColor(_ zone: CohortZone) -> Color {
        switch zone {
        case .promote: return Color.successText
        case .relegate: return Color.dangerText
        case .hold: return Color.textMuted
        }
    }

    private func load() async {
        defer { loaded = true }
        guard let cohorts = container.cohorts, let userID = auth.userID else { return }
        guard let membership = await cohorts.myMembership(userID: userID) else { return }
        async let seasonFetch = cohorts.season(id: membership.seasonId)
        async let standingsFetch = cohorts.standings(cohortID: membership.cohortId, meUserID: userID)
        season = await seasonFetch
        standings = await standingsFetch
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return LeaguesView().environmentObject(container).environmentObject(container.auth)
}
