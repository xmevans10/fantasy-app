import SwiftUI

struct LeaguesView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService
    /// Root tab selection — the signed-out empty state's "Sign in" CTA jumps to the
    /// Profile tab (4), where the actual sign-in buttons live. Defaults to a dead
    /// binding so previews/older call sites don't have to care.
    var selectedTab: Binding<Int> = .constant(0)

    @State private var season: Season?
    @State private var membership: CohortMembership?
    @State private var standings: [CohortStandingRow] = []
    @State private var loaded = false
    @State private var showLeaguesInfo = false
    /// Whether the promotion/relegation recap banner has been dismissed for the *current*
    /// season — reloaded from `UserDefaults` once `membership` resolves in `load()`.
    @State private var recapDismissed = false
    /// Who the trailing duel button on a standings row was last tapped for — `.sheet(item:)`
    /// so every scope's row shares one sheet instead of three near-identical `@State` bools.
    @State private var duelTarget: DuelTarget?

    /// A standings-row opponent, reduced to just what `DuelPickerSheet` needs. Cohort/season/
    /// friends rows are three different row types with no common protocol, so this is the
    /// shared shape the duel button normalizes them into.
    private struct DuelTarget: Identifiable {
        let id: String
        let username: String?
        let sport: Sport
    }

    // MARK: - FRIENDS scope (M20)

    /// Which ranking this tab is showing. `SEASON` is the 8-week rating ladder (M5 Phase F) and
    /// the default landing; `LEAGUE` is the pre-existing weekly-cohort XP standings (unchanged);
    /// `FRIENDS` is a client-side ranking over the caller + every accepted friend, keyed by
    /// whichever sport's rating the chip row currently selects.
    private enum LeagueScope: Int, CaseIterable {
        case season, league, friends
        var title: LocalizedStringKey {
            switch self {
            case .season: return "SEASON"
            case .league: return "LEAGUE"
            case .friends: return "FRIENDS"
            }
        }
    }

    @State private var scope: LeagueScope = .season
    @State private var seasonBoard: [SeasonStandingRow] = []
    @State private var seasonBoardSport: Sport?
    @State private var showSeasonInfo = false
    @State private var friendProfiles: [PublicProfile] = []
    /// Defaults to the signed-in user's best sport on load (see `bestSport()`), then tracks
    /// whatever the chip row picks.
    @State private var selectedSport: Sport = .nfl

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn && !DebugLaunch.autoOpenSeason {
                    signInPrompt
                } else {
                    VStack(spacing: 16) {
                        scopeSwitcher
                        Group {
                            switch scope {
                            case .season: seasonContent
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
            .toolbar {
                Wordmark.toolbarItem()
                ToolbarItem(placement: .topBarTrailing) {
                    Button { if scope == .season { showSeasonInfo = true } else { showLeaguesInfo = true } } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel(scope == .season ? "How seasons work" : "How leagues work")
                }
            }
        }
        .task { await load() }
        .onChange(of: selectedSport) { _, _ in
            if scope == .season { Task { await loadSeasonBoard() } }
        }
        .onChange(of: scope) { _, newScope in
            if newScope == .season, seasonBoardSport != selectedSport { Task { await loadSeasonBoard() } }
        }
        .onAppear {
            if DebugLaunch.autoOpenLeaguesInfo || HowItWorksSheet.shouldAutoPresent(feature: "leagues") {
                showLeaguesInfo = true
            }
        }
        .sheet(isPresented: $showLeaguesInfo) { leaguesInfoSheet }
        .sheet(isPresented: $showSeasonInfo) { seasonInfoSheet }
        .sheet(item: $duelTarget) { target in
            DuelPickerSheet(opponentID: target.id, opponentUsernameHint: target.username,
                            defaultSport: target.sport) { _, _ in }
        }
    }

    /// Trailing duel affordance shared by every standings row (~30 rating-matched players who
    /// never opted into anything — the largest duelable pool the app has). A separate button
    /// beside the row's `NavigationLink`, never a wrapper around it: a `Button` nested inside a
    /// `NavigationLink`'s label doesn't get its own tap target, it just adds a second action to
    /// the link's (see `PublicProfileView`'s friend/challenge row for the same constraint).
    private func duelButton(userID: String, username: String?, sport: Sport) -> some View {
        Button {
            Haptics.tap()
            duelTarget = DuelTarget(id: userID, username: username, sport: sport)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.surface0)
                .frame(width: 28, height: 28)
                .background(Color.ink)
                .clipShape(Circle())
        }
        .buttonStyle(PrimePressStyle())
        .accessibilityLabel(username.map { "Challenge \($0)" } ?? "Challenge this player")
    }

    private var signInPrompt: some View {
        EmptyStateView(symbol: "trophy.fill",
                       title: "Leagues",
                       message: "Sign in to get placed in a weekly league — every game you play earns XP toward the standings.",
                       actionTitle: "Sign in") { selectedTab.wrappedValue = 4 }
    }

    /// Copy derives from the spec's competitive glossary; the cutoff numbers come from
    /// `LeagueRules` against the loaded cohort (falling back to a full 30) so the sheet
    /// can never promise a headcount the standings bars don't show.
    private var leaguesInfoSheet: some View {
        let n = standings.isEmpty ? 30 : standings.count
        return HowItWorksSheet(
            title: "Weekly Leagues",
            intro: "A weekly XP race against players at your level. No joining, no invites — placement is automatic.",
            symbol: "trophy.fill",
            tint: Color.accentText,
            tintBackground: Color.accentBg,
            rules: [
                .init(symbol: "calendar",
                      title: "Placed every Monday",
                      detail: "Each Monday, every rated player is grouped into a fresh league of up to 30 by rating."),
                .init(symbol: "bolt.fill",
                      title: "Every game counts",
                      detail: "Every game you finish this week earns League XP — any format, ranked or not."),
                .init(symbol: "arrow.up.arrow.down",
                      title: LeagueRules.summaryLine(memberCount: n),
                      detail: "When the week ends, the top of the table is promoted to a tougher league and the bottom is relegated to an easier one."),
            ],
            callout: .init(symbol: "paintbrush.fill",
                           label: "The colored bars",
                           text: "Green rows are currently in the promotion zone, red rows in the relegation zone. Nothing is locked until the week's timer hits zero.",
                           tint: Color.successText,
                           background: Color.successBg),
            footnote: "Leagues never affect your rating — that only moves on ranked daily games.",
            startExpanded: DebugLaunch.autoOpenLeaguesInfo)
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
        } else if standings.isEmpty || DebugLaunch.forceLeagueCountdown {
            noLeagueYet
        } else {
            standingsList
        }
    }

    /// Honest unplaced state: placement only ever happens at the Monday rollover, so this
    /// counts down to it instead of implying that mid-week play gets you in (it doesn't —
    /// `bump_weekly_xp` is a no-op without a membership).
    private var noLeagueYet: some View {
        VStack(spacing: 14) {
            Image(systemName: "hourglass")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.accentText)
                .frame(width: 84, height: 84)
                .background(Color.accentBg)
                .clipShape(Circle())
            Text("YOUR LEAGUE STARTS MONDAY")
                .font(.title)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let next = LeagueRules.nextRollover(after: context.date)
                VStack(spacing: 4) {
                    Text(countdownText(from: context.date, to: next))
                        .font(.hero(30))
                        .foregroundStyle(Color.accentText)
                    Text(next.formatted(date: .abbreviated, time: .shortened))
                        .font(.label11)
                        .foregroundStyle(Color.textMuted)
                }
            }
            Text("You'll be placed with up to 29 players — every game you finish earns League XP.")
                .font(.body14)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func countdownText(from now: Date, to target: Date) -> String {
        let seconds = max(0, Int(target.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var standingsList: some View {
        ScrollView {
            VStack(spacing: 18) {
                recapBanner
                if let season { countdownCard(season).heroReveal(0) }
                zoneLegend
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
                Text("WEEK ENDS").font(.label11).foregroundStyle(Color.onAccent.opacity(0.75))
                Text(days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s")")
                    .font(.heading).foregroundStyle(Color.onAccent)
                Text(LeagueRules.summaryLine(memberCount: standings.count))
                    .font(.label11).foregroundStyle(Color.onAccent.opacity(0.75))
            }
            Spacer()
            Image(systemName: "calendar").font(.system(size: 22)).foregroundStyle(Color.onAccent)
        }
        .padding(16)
        .blockCard(fill: .accentFill)
    }

    /// Legend for the zone-colored rank bars — numbers come from the loaded cohort's actual
    /// cutoffs (`LeagueRules`), so a 9-player league honestly reads "TOP 4", never a
    /// hardcoded 5.
    private var zoneLegend: some View {
        HStack(spacing: 14) {
            legendItem(color: Color.successText,
                       text: LeagueRules.promoteLine(memberCount: standings.count))
            legendItem(color: Color.dangerText,
                       text: LeagueRules.relegateLine(memberCount: standings.count))
            Spacer()
        }
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text.uppercased()).font(.label11).foregroundStyle(Color.textMuted)
        }
    }

    // MARK: - Promotion/relegation recap (prior_zone)

    /// "You were promoted/relegated last week" — `prior_zone` is written by the rollover for
    /// exactly this banner. Shows once per season (dismissal keyed by season id) and only for
    /// actual movement; the held middle stays quiet.
    @ViewBuilder
    private var recapBanner: some View {
        let zone = DebugLaunch.forcePriorZone ?? membership?.priorZone
        if !recapDismissed, let zone, zone == "promoted" || zone == "relegated" {
            let promoted = zone == "promoted"
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: promoted ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(promoted ? Color.successText : Color.dangerText)
                Text(promoted
                     ? "You were promoted last week — welcome to a tougher league."
                     : "You were relegated last week — win this one and bounce right back.")
                    .font(.body14)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    recapDismissed = true
                    UserDefaults.standard.set(true, forKey: recapDismissKey)
                    Haptics.tap()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(promoted ? Color.successBg : Color.dangerBg)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    private var recapDismissKey: String {
        "leagueRecapDismissed_season_\(membership?.seasonId ?? 0)"
    }

    private func standingRow(_ row: CohortStandingRow) -> some View {
        HStack(spacing: 12) {
            // Everyone but "me" pushes to the public profile (M19) — my own row already has a
            // dedicated Profile tab, so tapping it would just be a confusing self-link. Only
            // the rank/avatar/name group is the link's label — the duel button below needs its
            // own tap target, which a `NavigationLink` wrapping the whole row would swallow.
            if row.isMe {
                standingRowLabel(row)
            } else {
                NavigationLink {
                    PublicProfileView(userID: row.userId, usernameHint: row.username)
                } label: {
                    standingRowLabel(row)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(row.weeklyXp) XP")
                .font(.statValue)
                .foregroundStyle(Color.textPrimary)
            if !row.isMe {
                duelButton(userID: row.userId, username: row.username, sport: selectedSport)
            }
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

    private func standingRowLabel(_ row: CohortStandingRow) -> some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.hero(18))
                .foregroundStyle(zoneColor(row.zone))
                .frame(width: 28, alignment: .leading)
            AvatarView(avatar: row.avatar, size: 28, emojiFallback: nil)
            Text(row.displayName)
                .font(row.isMe ? .bodyStrong : .body14)
                .foregroundStyle(Color.textPrimary)
        }
    }

    private func zoneColor(_ zone: CohortZone) -> Color {
        switch zone {
        case .promote: return Color.successText
        case .relegate: return Color.dangerText
        case .hold: return Color.textMuted
        }
    }

    // MARK: - SEASON scope content (M5 Phase F — 8-week rating ladder)

    @ViewBuilder
    private var seasonContent: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if container.currentSeason == nil {
            noSeasonYet
        } else {
            seasonStandingsList
        }
    }

    /// Between seasons or offline: the rollover opens the next season server-side, so this is an
    /// honest "check back" rather than implying play right now counts toward a season that isn't open.
    private var noSeasonYet: some View {
        EmptyStateView(symbol: "trophy.fill",
                       title: "Season starting soon",
                       message: "The next 8-week rating season hasn't opened yet. Your ranked games will place you on the ladder the moment it does.")
    }

    private var seasonStandingsList: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let season = container.currentSeason {
                    seasonHero.heroReveal(0)
                    seasonCountdownCard(season).heroReveal(1)
                }
                sportChipRow.heroReveal(2)
                if seasonBoard.isEmpty {
                    Text("No ranked games yet this season — play a ranked daily to land on the board.")
                        .font(.body14)
                        .foregroundStyle(Color.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                } else {
                    VStack(spacing: 10) {
                        ForEach(seasonBoard) { row in seasonStandingRow(row) }
                    }
                    .heroReveal(3)
                }
            }
            .padding(16)
        }
    }

    /// My season rank + rating hero. Rating is the instant local season value (seeded from a
    /// soft-reset of the all-time rating); rank comes from the board's own-row. Reuses `RankWidget`
    /// (the Home rank hero) so tier metal/foil-for-Legend is identical to the all-time rating card.
    private var seasonHero: some View {
        let rating = container.seasonRating(for: selectedSport)
            ?? seasonBoard.first(where: \.isMe)?.rating
            ?? RatingEngine.startingRating
        let myRank = seasonBoard.first(where: \.isMe)?.rank
        return VStack(spacing: 10) {
            RankWidget(sport: selectedSport, rating: rating)
            if let myRank {
                Text("SEASON RANK #\(myRank)")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
            }
        }
    }

    private func seasonCountdownCard(_ season: RatingSeason) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SEASON ENDS").font(.label11).foregroundStyle(Color.onAccent.opacity(0.75))
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(RatingSeasonRules.remainingText(now: context.date, end: season.endsAt))
                        .font(.heading).foregroundStyle(Color.onAccent)
                }
                Text("Top the ladder to earn this season's tier badge")
                    .font(.label11).foregroundStyle(Color.onAccent.opacity(0.75))
            }
            Spacer()
            Image(systemName: "hourglass").font(.system(size: 22)).foregroundStyle(Color.onAccent)
        }
        .padding(16)
        .blockCard(fill: .accentFill)
    }

    private func seasonStandingRow(_ row: SeasonStandingRow) -> some View {
        HStack(spacing: 12) {
            if row.isMe {
                seasonStandingRowLabel(row)
            } else {
                NavigationLink {
                    PublicProfileView(userID: row.userId, usernameHint: row.username)
                } label: {
                    seasonStandingRowLabel(row)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Image(systemName: row.tier.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(row.tier.color)
            Text("\(row.rating)")
                .font(.statValue)
                .foregroundStyle(Color.textPrimary)
            if !row.isMe {
                duelButton(userID: row.userId, username: row.username, sport: selectedSport)
            }
        }
        .padding(12)
        .background(row.isMe ? Color.accentBg : Color.clear)
        .cardSurface()
    }

    private func seasonStandingRowLabel(_ row: SeasonStandingRow) -> some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.hero(18))
                .foregroundStyle(row.tier.color)
                .frame(width: 28, alignment: .leading)
            AvatarView(avatar: row.avatar, size: 28, emojiFallback: nil)
            Text(row.displayName)
                .font(row.isMe ? .bodyStrong : .body14)
                .foregroundStyle(Color.textPrimary)
        }
    }

    private var seasonInfoSheet: some View {
        HowItWorksSheet(
            title: "Rating Seasons",
            intro: "An 8-week competitive ladder. Every ranked daily moves your season rating — climb as high as you can before the season ends.",
            symbol: "trophy.fill",
            tint: Color.accentText,
            tintBackground: Color.accentBg,
            rules: [
                .init(symbol: "arrow.triangle.2.circlepath",
                      title: "A fresh ladder every 8 weeks",
                      detail: "Each season starts you partway back toward the middle, so the ladder is always up for grabs — your all-time rating never resets."),
                .init(symbol: "bolt.fill",
                      title: "Ranked games move you",
                      detail: "Only ranked daily games count toward your season rating. Community and unranked play don't move it."),
                .init(symbol: "medal.fill",
                      title: "Earn a tier badge",
                      detail: "When the season closes, the highest tier you reached is minted as a badge on your Profile — Legend badges shimmer."),
            ],
            footnote: "Season ratings are separate from your permanent all-time rating and from weekly Leagues.",
            startExpanded: false)
    }

    /// Fetches the active-season board for the currently-selected sport. Cached by sport so
    /// re-selecting the same chip doesn't refetch (mirrors how the FRIENDS list recomputes on
    /// `selectedSport`, just async because the season board is server-ranked).
    private func loadSeasonBoard() async {
        guard container.currentSeason != nil, let seasons = container.seasons else {
            seasonBoard = []; return
        }
        let sport = selectedSport
        seasonBoard = await seasons.leaderboard(sport: sport)
        seasonBoardSport = sport
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

    private func friendLeaderboardRow(_ row: FriendsLeaderboardRow, rank: Int) -> some View {
        HStack(spacing: 12) {
            // Same convention as `standingRow`: only other players' rows push to their public
            // profile — my own row already lives on the Profile tab.
            if row.isMe {
                friendLeaderboardRowLabel(row, rank: rank)
            } else {
                NavigationLink {
                    PublicProfileView(userID: row.userID, usernameHint: row.username)
                } label: {
                    friendLeaderboardRowLabel(row, rank: rank)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(row.rating)")
                .font(.statValue)
                .foregroundStyle(Color.textPrimary)
            if !row.isMe {
                duelButton(userID: row.userID, username: row.username, sport: selectedSport)
            }
        }
        .padding(12)
        .background(row.isMe ? Color.accentBg : Color.clear)
        .cardSurface()
    }

    private func friendLeaderboardRowLabel(_ row: FriendsLeaderboardRow, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.hero(18))
                .foregroundStyle(Color.textMuted)
                .frame(width: 28, alignment: .leading)
            AvatarView(avatar: row.avatar, size: 28, emojiFallback: nil)
            Text(row.username ?? "Player")
                .font(row.isMe ? .bodyStrong : .body14)
                .foregroundStyle(Color.textPrimary)
        }
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
        if container.currentSeason == nil { await container.refreshCurrentSeason() }
        await loadSeasonBoard()
        guard let userID = auth.userID else { return }
        async let friendsFetch: [PublicProfile] = container.social?.friendProfiles() ?? []
        if let cohorts = container.cohorts, let membership = await cohorts.myMembership(userID: userID) {
            async let seasonFetch = cohorts.season(id: membership.seasonId)
            async let standingsFetch = cohorts.standings(cohortID: membership.cohortId, meUserID: userID)
            season = await seasonFetch
            standings = await standingsFetch
            self.membership = membership
            recapDismissed = UserDefaults.standard.bool(
                forKey: "leagueRecapDismissed_season_\(membership.seasonId)")
        }
        friendProfiles = await friendsFetch
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return LeaguesView().environmentObject(container).environmentObject(container.auth)
}
