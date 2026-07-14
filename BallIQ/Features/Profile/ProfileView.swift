import SwiftUI
import AuthenticationServices

struct ProfileView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var currentNonce: String?
    @State private var notificationSettings = NotificationSettings.allEnabled
    @State private var showStats = false
    @State private var showModeration = false
    @State private var showIdentityEditor = false
    @State private var showFriends = false

    /// The player's strongest sport headlines the hero (ties favor NFL — `allCases` order).
    private var bestSport: Sport {
        Sport.allCases.reduce(Sport.nfl) {
            container.rating(for: $1) > container.rating(for: $0) ? $1 : $0
        }
    }
    private var rating: Int { container.rating(for: bestSport) }
    private var tier: Tier { Tier.forRating(rating) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if auth.isSignedIn && container.identity.username == nil {
                        claimUsernameCard.heroReveal(0)
                    }
                    heroCard.heroReveal(1)
                    statRow.heroReveal(2)
                    statsRow.heroReveal(3)
                    if auth.isSignedIn { friendsRow.heroReveal(4) }
                    ratingsCard.heroReveal(5)
                    if auth.isSignedIn && container.identity.username != nil {
                        shareCardRow.heroReveal(6)
                    }
                    if auth.isSignedIn { favoriteTeamsCard.heroReveal(7) }
                    if auth.isSignedIn { notificationsCard.heroReveal(8) }
                    if container.isAdmin { moderationRow.heroReveal(9) }
                    accountCard.heroReveal(10)
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Wordmark() } }
            .navigationDestination(isPresented: $showStats) {
                StatsView().environmentObject(container)
            }
            .navigationDestination(isPresented: $showModeration) {
                ModerationQueueView().environmentObject(container)
            }
            .navigationDestination(isPresented: $showFriends) {
                FriendsView().environmentObject(container).environmentObject(auth)
            }
        }
        .sheet(isPresented: $showIdentityEditor) {
            IdentityEditorSheet().environmentObject(container)
        }
        .task { if auth.isSignedIn { notificationSettings = await container.loadNotificationSettings() } }
        .onAppear {
            if DebugLaunch.autoOpenStats { showStats = true }
            if DebugLaunch.autoOpenModeration { showModeration = true }
        }
    }

    /// Entry to the full Stats screen (rating history chart, per-sport summaries).
    private var statsRow: some View {
        Button { showStats = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stats").font(.title).foregroundStyle(Color.textPrimary)
                    Text("RATING HISTORY & TRENDS").font(.label11).foregroundStyle(Color.textMuted)
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

    /// Prompts a signed-in-but-anonymous player to claim `profiles.username` — without it,
    /// Versus challenges and Friends have nothing to address the player by, so this is the
    /// root of the identity loop the rest of M19 depends on.
    private var claimUsernameCard: some View {
        Button { showIdentityEditor = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 26, weight: .black)).foregroundStyle(Color.onVolt)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLAIM YOUR USERNAME").font(.heading).foregroundStyle(Color.onVolt)
                    Text("UNLOCKS VERSUS CHALLENGES & FRIENDS").font(.label11).foregroundStyle(Color.onVolt.opacity(0.75))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.onVolt.opacity(0.75))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .blockCard(fill: .voltFill)
        }
        .buttonStyle(PrimePressStyle())
    }

    /// Entry to the friends hub — incoming requests, friends list, add-by-username.
    private var friendsRow: some View {
        Button { showFriends = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Friends").font(.title).foregroundStyle(Color.textPrimary)
                    Text("REQUESTS & CHALLENGES").font(.label11).foregroundStyle(Color.textMuted)
                }
                Spacer()
                if container.pendingFriendRequests > 0 {
                    Text("\(container.pendingFriendRequests)")
                        .font(.label12).foregroundStyle(Color.onDanger)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.dangerFill)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .cardSurface()
        }
        .buttonStyle(PrimePressStyle())
    }

    /// Shareable identity card — only offered once a username exists, since `@nil` reads
    /// poorly and the whole point is giving friends something to find you by.
    private var shareCardRow: some View {
        let card = ProfileShareCardView(
            username: container.identity.username ?? "",
            avatar: container.identity.avatar?.isEmpty == false ? container.identity.avatar! : "🏟️",
            sport: bestSport, tier: tier, rating: rating,
            streak: container.streak, level: container.level)
        return ShareLink(item: card.rendered(), preview: SharePreview("My BallIQ profile", image: card.rendered())) {
            Label("SHARE MY CARD", systemImage: "square.and.arrow.up").ctaLabel()
        }
        .buttonStyle(PrimePressStyle())
        .simultaneousGesture(TapGesture().onEnded {
            container.track(.shareTapped, ["surface": "profile_card"])
        })
    }

    /// Entry to the moderation review queue — admin accounts only (`profiles.is_admin`).
    private var moderationRow: some View {
        Button { showModeration = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.warningText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Moderation").font(.title).foregroundStyle(Color.textPrimary)
                    Text("REPORTED COMMUNITY PUZZLES").font(.label11).foregroundStyle(Color.textMuted)
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

    // MARK: - Favorite teams

    private var favoriteTeamsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FAVORITE TEAMS").font(.label12).foregroundStyle(Color.textMuted)
            ForEach(Sport.allCases.filter(\.hasTeams)) { favoriteTeamRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private func favoriteTeamRow(_ sport: Sport) -> some View {
        let selected = container.favoriteTeams.team(for: sport)
        // A picked team should read as that team, not a generic muted pill — same identity
        // signal every player card already carries via `TeamColors`.
        let team = selected.map { TeamColors.palette(sport: sport, abbr: $0) }
        return HStack(spacing: 12) {
            Image(systemName: sport.symbol).font(.system(size: 14)).foregroundStyle(sport.cardFill)
            Text(sport.displayName).font(.body14).foregroundStyle(Color.textPrimary)
            Spacer()
            Menu {
                Button("None") { setFavoriteTeam(nil, for: sport) }
                ForEach(container.catalog.teams(for: sport), id: \.self) { abbr in
                    Button(abbr) { setFavoriteTeam(abbr, for: sport) }
                }
            } label: {
                HStack(spacing: 6) {
                    if let selected, let url = sport.teamLogoURL(forAbbr: selected) {
                        AsyncImage(url: url) { phase in
                            if let img = phase.image { img.resizable().scaledToFit() }
                        }
                        .frame(width: 18, height: 18)
                    }
                    Text(selected ?? "Pick a team").font(.label12)
                        .foregroundStyle(team?.onPrimary ?? Color.textMuted)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                        .foregroundStyle(team != nil ? team!.onPrimary.opacity(0.7) : Color.textMuted)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(team?.primary ?? Color.surfaceMuted)
                .clipShape(Capsule())
            }
        }
    }

    private func setFavoriteTeam(_ abbr: String?, for sport: Sport) {
        var updated = container.favoriteTeams
        updated.setTeam(abbr, for: sport)
        Task { await container.saveFavoriteTeams(updated) }
    }

    // MARK: - Notifications

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOTIFICATIONS").font(.label12).foregroundStyle(Color.textMuted)
            notificationToggle("Streak at risk", \.streakAtRisk)
            notificationToggle("League position", \.leaguePosition)
            notificationToggle("Versus challenges", \.versusChallenge)
            notificationToggle("Friend requests", \.friendRequest)
            notificationToggle("Season ending", \.seasonEnd)
            Button {
                Task { await PushNotificationManager.requestAuthorizationAndRegister() }
            } label: {
                Text("ENABLE PUSH NOTIFICATIONS")
                    .font(.label12).foregroundStyle(Color.accentText)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.accentBg)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .buttonStyle(PrimePressStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private func notificationToggle(_ label: String, _ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { notificationSettings[keyPath: keyPath] },
            set: { newValue in
                notificationSettings[keyPath: keyPath] = newValue
                Task { await container.saveNotificationSettings(notificationSettings) }
            }
        ))
        .font(.body14)
        .tint(Color.accentFill)
    }

    private var heroCard: some View {
        VStack(spacing: 6) {
            if auth.isSignedIn, let username = container.identity.username {
                identityLine(username: username)
                    .padding(.bottom, 4)
            }
            Image(systemName: tier.symbol)
                .font(.system(size: 40, weight: .black))
                .foregroundStyle(tier.color)
            Text(tier.name.uppercased())
                .font(.heading).foregroundStyle(Color.onAccent.opacity(0.85))
            CountUpText(value: rating, font: .hero(64), color: .onAccent)
            Text("\(bestSport.displayName) RATING").font(.label12)
                .foregroundStyle(Color.onAccent.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .blockCard(fill: .accentFill)
    }

    /// Avatar + `@username` + pencil edit, shown atop the hero once identity is claimed.
    private func identityLine(username: String) -> some View {
        let avatar = container.identity.avatar?.isEmpty == false ? container.identity.avatar! : "🏟️"
        return HStack(spacing: 8) {
            Text(avatar)
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
                .background(Color.onAccent.opacity(0.14))
                .clipShape(Circle())
            Text("@\(username)")
                .font(.custom(FontName.condBlack, size: 16))
                .foregroundStyle(Color.onAccent)
            Button { showIdentityEditor = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.onAccent.opacity(0.85))
                    .padding(6)
                    .background(Color.onAccent.opacity(0.14))
                    .clipShape(Circle())
            }
            .buttonStyle(PrimePressStyle())
        }
    }

    private var statRow: some View {
        HStack(spacing: 16) {
            stat("LEVEL", "\(container.level)")
            Divider().frame(height: 32)
            stat("XP", "\(container.xp)")
            Divider().frame(height: 32)
            stat("STREAK", "\(container.streak)")
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            Text(value).font(.hero(26)).foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Ratings (per sport)

    private var ratingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RATINGS").font(.label12).foregroundStyle(Color.textMuted)
            ForEach(Sport.allCases) { ratingRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private func ratingRow(_ sport: Sport) -> some View {
        let rating = container.rating(for: sport)
        let tier = Tier.forRating(rating)
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: sport.symbol).font(.system(size: 14)).foregroundStyle(tier.color)
                Text(sport.displayName).font(.heading).foregroundStyle(Color.textPrimary)
                Spacer()
                Text(tier.name.uppercased()).font(.label11).foregroundStyle(tier.color)
                Text("\(rating)").font(.hero(22)).foregroundStyle(Color.textPrimary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceMuted)
                    Capsule().fill(tier.color)
                        .frame(width: geo.size.width * tierProgress(rating: rating, tier: tier))
                }
            }
            .frame(height: 6)
            if let floor = tier.nextTierFloor {
                Text("\(floor - rating) to \(Tier.forRating(floor).name)")
                    .font(.label11).foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("Max tier").font(.label11).foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Fraction (0–1) of the way through the current tier's rating band.
    private func tierProgress(rating: Int, tier: Tier) -> CGFloat {
        let lo = tier.range.lowerBound, hi = tier.range.upperBound
        guard hi > lo else { return 1 }
        return CGFloat(min(max(rating - lo, 0), hi - lo)) / CGFloat(hi - lo)
    }

    @ViewBuilder
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ACCOUNT").font(.label12).foregroundStyle(Color.textMuted)
            if auth.isSignedIn {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.successText)
                    Text("Signed in — progress syncs across devices")
                        .font(.body14).foregroundStyle(Color.textPrimary)
                }
                Button(role: .destructive) {
                    auth.signOut()
                    container.handleSignedOut()
                } label: {
                    Text("SIGN OUT")
                        .font(.heading).foregroundStyle(Color.dangerText)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.dangerBg)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(PrimePressStyle())
            } else {
                Text("Sign in to save your progress and climb the leaderboards.")
                    .font(.body14).foregroundStyle(Color.textSecondary)
                SignInWithAppleButton(.signIn) { request in
                    let raw = AuthService.makeNonce()
                    currentNonce = raw
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AuthService.sha256(raw)
                } onCompletion: { result in handle(result) }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

                Button {
                    Task {
                        try? await container.auth.signInWithProvider("google")
                        await container.syncIfSignedIn()
                        if container.isSignedIn {
                            container.track(.signInCompleted, ["provider": "google", "surface": "profile"])
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 15, weight: .bold))
                        Text("Continue with Google").font(.bodyStrong)
                    }
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let authorization) = result,
              let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let raw = currentNonce else { return }
        Task {
            try? await container.auth.signInWithApple(identityToken: token, rawNonce: raw)
            await container.syncIfSignedIn()
            if container.isSignedIn {
                container.track(.signInCompleted, ["provider": "apple", "surface": "profile"])
            }
        }
    }
}
