import SwiftUI

struct LeaguesView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var season: Season?
    @State private var standings: [CohortStandingRow] = []
    @State private var loaded = false

    // MARK: - FRIENDS scope (M20)

    /// Which ranking this tab is showing. `LEAGUE` is the pre-existing weekly-cohort
    /// standings (unchanged); `FRIENDS` is a client-side ranking over the caller + every
    /// accepted friend, keyed by whichever sport's rating the chip row currently selects.
    private enum LeagueScope: Int, CaseIterable {
        case league, friends
        var title: String { self == .league ? "LEAGUE" : "FRIENDS" }
    }

    @State private var scope: LeagueScope = .league
    @State private var friendProfiles: [PublicProfile] = []
    /// Defaults to the signed-in user's best sport on load (see `bestSport()`), then tracks
    /// whatever the chip row picks.
    @State private var selectedSport: Sport = .nfl

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    signInPrompt
                } else {
                    VStack(spacing: 16) {
                        scopeSwitcher
                        Group {
                            switch scope {
                            case .league: leagueContent
                            case .friends: friendsContent
                            }
                        }
                    }
                    .padding(.top, 12)
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

    /// Two-way scope switcher, reusing `SetupSegmentedControl` (Home's per-game setup
    /// screens) rather than inventing a new chip style for what is functionally the same
    /// "pick one of a couple options" control.
    private var scopeSwitcher: some View {
        SetupSegmentedControl(options: LeagueScope.allCases.map(\.title),
                               selectedIndex: scope.rawValue) { i in
            Haptics.tap()
            withAnimation(Motion.snap) { scope = LeagueScope(rawValue: i) ?? .league }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var leagueContent: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if standings.isEmpty {
            noLeagueYet
        } else {
            standingsList
        }
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

    @ViewBuilder
    private func standingRow(_ row: CohortStandingRow) -> some View {
        // Everyone but "me" pushes to the public profile (M19) — my own row already has a
        // dedicated Profile tab, so tapping it would just be a confusing self-link.
        if row.isMe {
            standingRowContent(row)
        } else {
            NavigationLink {
                PublicProfileView(userID: row.userId, usernameHint: row.username)
            } label: {
                standingRowContent(row)
            }
            .buttonStyle(.plain)
        }
    }

    private func standingRowContent(_ row: CohortStandingRow) -> some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.hero(18))
                .foregroundStyle(zoneColor(row.zone))
                .frame(width: 28, alignment: .leading)
            if let avatar = row.avatar, !avatar.isEmpty {
                Text(avatar).font(.system(size: 22)).frame(width: 28, height: 28)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.textMuted)
            }
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

    // MARK: - FRIENDS scope content

    @ViewBuilder
    private var friendsContent: some View {
        // Friend profiles load alongside the league standings in `load()`, so this shares
        // the same `loaded` flag rather than tracking a second spinner state.
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if friendProfiles.isEmpty {
            EmptyStateView(symbol: "person.2.fill",
                           title: "No friends yet",
                           message: "Add friends by username from your Profile to see how you stack up.")
        } else {
            friendsLeaderboardList
        }
    }

    private var friendsLeaderboardList: some View {
        ScrollView {
            VStack(spacing: 18) {
                sportChipRow.heroReveal(0)
                VStack(spacing: 10) {
                    ForEach(Array(rankedFriends.enumerated()), id: \.element.id) { i, row in
                        friendLeaderboardRow(row, rank: i + 1)
                    }
                }
                .heroReveal(1)
            }
            .padding(16)
        }
    }

    private var sportChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Sport.allCases) { sport in
                    PrimeChip(label: sport.abbreviation, active: sport == selectedSport) {
                        selectedSport = sport
                    }
                }
            }
            .padding(.horizontal, 1) // keeps the first/last chip's press-shadow from clipping
        }
    }

    /// The caller's own row, rebuilt whenever `selectedSport` changes so its rating tracks
    /// the currently-selected chip.
    private var meLeaderboardRow: FriendsLeaderboardRow {
        FriendsLeaderboardRow(userID: auth.userID ?? "",
                              username: container.identity.username,
                              avatar: container.identity.avatar,
                              rating: container.rating(for: selectedSport),
                              isMe: true)
    }

    private var rankedFriends: [FriendsLeaderboardRow] {
        Self.friendsLeaderboard(me: meLeaderboardRow, friends: friendProfiles, sport: selectedSport)
    }

    @ViewBuilder
    private func friendLeaderboardRow(_ row: FriendsLeaderboardRow, rank: Int) -> some View {
        // Same convention as `standingRow`: only other players' rows push to their public
        // profile — my own row already lives on the Profile tab.
        if row.isMe {
            friendLeaderboardRowContent(row, rank: rank)
        } else {
            NavigationLink {
                PublicProfileView(userID: row.userID, usernameHint: row.username)
            } label: {
                friendLeaderboardRowContent(row, rank: rank)
            }
            .buttonStyle(.plain)
        }
    }

    private func friendLeaderboardRowContent(_ row: FriendsLeaderboardRow, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.hero(18))
                .foregroundStyle(Color.textMuted)
                .frame(width: 28, alignment: .leading)
            if let avatar = row.avatar, !avatar.isEmpty {
                Text(avatar).font(.system(size: 22)).frame(width: 28, height: 28)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.textMuted)
            }
            Text(row.username ?? "Player")
                .font(row.isMe ? .bodyStrong : .body14)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text("\(row.rating)")
                .font(.statValue)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(12)
        .background(row.isMe ? Color.accentBg : Color.clear)
        .cardSurface()
    }

    /// One row of the FRIENDS leaderboard: either the caller or a friend, projected down to
    /// just what the ranking/rendering needs. Kept separate from `PublicProfile` so the
    /// caller's own row (which has no `PublicProfile` — it comes from `container.identity`/
    /// `container.rating(for:)`) can merge into the same list uniformly.
    struct FriendsLeaderboardRow: Identifiable, Equatable {
        let userID: String
        let username: String?
        let avatar: String?
        let rating: Int
        let isMe: Bool
        var id: String { userID }
    }

    /// Merges the caller's own row with every accepted friend's `PublicProfile`, ranks by
    /// `sport`'s rating (descending), and breaks ties by username (ascending, missing
    /// usernames last) so equal-rated players always render in the same order rather than
    /// reshuffling across re-renders. Pure — no repository/network dependency — so it's
    /// unit-tested directly (see `FriendsLeaderboardTests`).
    static func friendsLeaderboard(me: FriendsLeaderboardRow, friends: [PublicProfile], sport: Sport) -> [FriendsLeaderboardRow] {
        var rows = friends.map {
            FriendsLeaderboardRow(userID: $0.id, username: $0.username, avatar: $0.avatar,
                                  rating: $0.rating(for: sport), isMe: false)
        }
        rows.append(me)
        rows.sort { a, b in
            if a.rating != b.rating { return a.rating > b.rating }
            switch (a.username, b.username) {
            case let (u1?, u2?): return u1.localizedCaseInsensitiveCompare(u2) == .orderedAscending
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.userID < b.userID
            }
        }
        return rows
    }

    /// The signed-in user's strongest sport by local rating — mirrors `PublicProfile.bestSport`'s
    /// convention (ties favor `Sport.allCases` order) so the default chip matches what a
    /// friend would see if they looked *us* up.
    private func bestSport() -> Sport {
        Sport.allCases.reduce(Sport.nfl) { container.rating(for: $1) > container.rating(for: $0) ? $1 : $0 }
    }

    private func load() async {
        defer { loaded = true }
        selectedSport = bestSport()
        guard let userID = auth.userID else { return }
        async let friendsFetch: [PublicProfile] = container.social?.friendProfiles() ?? []
        if let cohorts = container.cohorts, let membership = await cohorts.myMembership(userID: userID) {
            async let seasonFetch = cohorts.season(id: membership.seasonId)
            async let standingsFetch = cohorts.standings(cohortID: membership.cohortId, meUserID: userID)
            season = await seasonFetch
            standings = await standingsFetch
        }
        friendProfiles = await friendsFetch
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return LeaguesView().environmentObject(container).environmentObject(container.auth)
}
