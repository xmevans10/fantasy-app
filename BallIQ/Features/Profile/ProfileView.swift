import SwiftUI
import AuthenticationServices

struct ProfileView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    /// Tab switch out of Profile — lets the empty-state CTA ("Play a puzzle on Home") be a
    /// working button. Defaulted so `ProfileView()` (tests, previews) keeps compiling.
    var selectedTab: Binding<Int> = .constant(0)

    @State private var currentNonce: String?
    @State private var notificationSettings = NotificationSettings.allEnabled
    @State private var showCareer = false
    @State private var showModeration = false
    @State private var showIdentityEditor = false
    @State private var showFriends = false
    @State private var showRatingLadder = false
    /// Which sport's club picker is open (`TeamPicker` sheet) — nil = closed.
    @State private var pickingTeamFor: Sport?

    /// The full career log — loaded once per appearance into state since `gameLog` is an actor.
    /// Everything career-hero/highlight-reel/stat-row renders is a pure function of this array.
    @State private var careerRows: [GameResult] = []

    // Account deletion (App Store Guideline 5.1.1(v)).
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var deletionError: String?
    /// Shown after the server confirms. Apple's reviewer records this flow end to end, so the
    /// deletion needs a visible terminal state rather than the screen quietly reverting to
    /// signed-out — and the user deserves to be told it actually happened.
    @State private var deletionConfirmed = false
    /// Surfaced when a provider sign-in fails — previously swallowed by `try?`.
    @State private var signInError: String?

    /// The player's strongest sport headlines the hero (ties favor NFL — `allCases` order).
    private var bestSport: Sport {
        Sport.allCases.reduce(Sport.nfl) {
            container.rating(for: $1) > container.rating(for: $0) ? $1 : $0
        }
    }
    private var rating: Int { container.rating(for: bestSport) }
    private var tier: Tier { Tier.forRating(rating) }
    private var careerSummary: CareerSummary { CareerSummary(careerRows) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if auth.isSignedIn && container.identity.username == nil {
                        claimUsernameCard.heroReveal(0)
                    }
                    heroCard.heroReveal(1)
                    statRow.heroReveal(2)
                    highlightReel.heroReveal(3)
                    if !container.seasonBadges.isEmpty { seasonBadgesCard.heroReveal(4) }
                    careerRow.heroReveal(5)
                    if auth.isSignedIn { friendsRow.heroReveal(6) }
                    ratingsCard.heroReveal(7)
                    if auth.isSignedIn && container.identity.username != nil {
                        shareCardRow.heroReveal(8)
                    }
                    if auth.isSignedIn { favoriteTeamsCard.heroReveal(9) }
                    if auth.isSignedIn { notificationsCard.heroReveal(10) }
                    if container.isAdmin { moderationRow.heroReveal(11) }
                    accountCard.heroReveal(12)
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Wordmark.toolbarItem() }
            .navigationDestination(isPresented: $showCareer) {
                CareerView().environmentObject(container)
            }
            .navigationDestination(isPresented: $showModeration) {
                ModerationQueueView().environmentObject(container)
            }
            .navigationDestination(isPresented: $showFriends) {
                FriendsView().environmentObject(container).environmentObject(auth)
            }
            .navigationDestination(isPresented: $showRatingLadder) {
                RatingLadderView().environmentObject(container)
            }
        }
        .sheet(isPresented: $showIdentityEditor) {
            IdentityEditorSheet().environmentObject(container)
        }
        .task { if auth.isSignedIn { notificationSettings = await container.loadNotificationSettings() } }
        .task { careerRows = await container.gameLog.all() }
        .onAppear {
            if DebugLaunch.autoOpenStats { showCareer = true }
            if DebugLaunch.autoOpenModeration { showModeration = true }
        }
        // Attached to the whole screen rather than to the DELETE ACCOUNT button, because that
        // button lives inside `if auth.isSignedIn` — a successful deletion signs the user out,
        // which tears the button (and anything modally attached to it) out of the hierarchy
        // before the confirmation could ever appear. Apple asks for a recording of the flow
        // "from initiation to confirmation", so the confirmation has to outlive the button.
        .alert("Account deleted", isPresented: $deletionConfirmed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your account and all of its data have been permanently deleted.")
        }
        .alert("Sign-in failed", isPresented: Binding(
            get: { signInError != nil }, set: { if !$0 { signInError = nil } }
        )) {
            Button("OK", role: .cancel) { signInError = nil }
        } message: {
            Text(signInError ?? "")
        }
        .alert("Couldn't delete account", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    /// Entry to the full Career screen (accuracy, records, fun facts) — replaces the old
    /// rating-only Stats screen.
    private var careerRow: some View {
        Button { showCareer = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Career").font(.title).foregroundStyle(Color.textPrimary)
                    Text("ACCURACY, RECORDS & FUN FACTS").font(.label11).foregroundStyle(Color.textMuted)
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
            container.track(.shareTapped, AnalyticsEvent.shareProperties(
                surface: "profile", format: "profile", artifact: .profileImage,
                extra: ["sport": bestSport.rawValue]))
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
        .sheet(item: $pickingTeamFor) { sport in
            TeamPicker(selection: Binding(
                get: { container.favoriteTeams.team(for: sport) },
                set: { setFavoriteTeam($0, for: sport) }),
                sport: sport, fallbackAbbrs: container.catalog.teams(for: sport))
        }
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
            // A sheet, not a Menu: soccer carries 201 clubs, and a flat unsearchable menu of
            // bare abbreviations is unusable at that scale (see `TeamPicker`).
            Button { pickingTeamFor = sport } label: {
                HStack(spacing: 6) {
                    if let selected, let url = sport.teamLogoURL(forAbbr: selected) {
                        RemoteImage(url: url, targetSize: CGSize(width: 18, height: 18))
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
            notificationToggle("Daily puzzle drop", \.dailyDrop)
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

    /// Leads with the player's own performance rather than their per-sport Elo — the user's own
    /// framing of what this screen should headline. A brand-new account still carries a default
    /// 1000/Silver rating, which used to render here indistinguishable from an earned one; this
    /// hero shows nothing rating-shaped until there's at least one real game to back it.
    private var heroCard: some View {
        Group {
            if careerRows.isEmpty {
                careerHeroEmpty
            } else {
                careerHeroFilled
            }
        }
    }

    private var careerHeroFilled: some View {
        VStack(spacing: 6) {
            avatarBadge
            if auth.isSignedIn, let username = container.identity.username {
                identityLine(username: username)
            }
            if let accuracy = careerSummary.accuracy {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    CountUpText(value: Int((accuracy * 100).rounded()), font: .hero(64), color: .onAccent)
                    Text("%").font(.hero(64)).foregroundStyle(Color.onAccent)
                }
            } else {
                Text("—").font(.hero(64)).foregroundStyle(Color.onAccent)
            }
            Text("\(careerSummary.cardsJudged) cards judged · \(careerSummary.games) games")
                .font(.label12).foregroundStyle(Color.onAccent.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .blockCard(fill: .accentFill)
        .overlay(alignment: .topTrailing) { tierCapsule.padding(10) }
    }

    /// A 0-game account: the old default-1000/Silver hero read as an earned rank, which it
    /// wasn't. This reads as an invitation instead, and deliberately drops the tier capsule too
    /// — a tier badge on a card with no rating history is the exact same bug in miniature.
    private var careerHeroEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 72, height: 72)
                .background(Color.onAccent.opacity(0.14))
                .clipShape(Circle())
            Text("YOUR CAREER STARTS TODAY")
                .font(.title).foregroundStyle(Color.onAccent)
                .multilineTextAlignment(.center)
            Text("Every puzzle you play builds your stats — accuracy, streaks, and the fun facts below.")
                .font(.body14).foregroundStyle(Color.onAccent.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button { selectedTab.wrappedValue = 0 } label: {
                HStack(spacing: 6) {
                    Text("PLAY A PUZZLE ON HOME").font(.label12).foregroundStyle(Color.onAccent)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.onAccent)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.onAccent.opacity(0.16))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.onAccent.opacity(0.4), lineWidth: 1.5))
            }
            .buttonStyle(PrimePressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .blockCard(fill: .accentFill)
    }

    /// The demoted Elo: still visible at a glance (tapping the summary row below reaches the
    /// full ladder), just no longer the first thing the screen says.
    private var tierCapsule: some View {
        HStack(spacing: 4) {
            Image(systemName: tier.symbol).font(.system(size: 10, weight: .black))
            Text(tier.name.uppercased()).font(.label11)
        }
        .foregroundStyle(tier.onColor)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tier.color)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 1.5))
    }

    /// The hero's face: the player's chosen emoji avatar in a big tier-ringed circle
    /// (replacing the old flat gray `tier.symbol`, which read as a stale placeholder icon).
    /// Signed-in players get a pencil badge + tap-to-edit (the avatar picker lived buried
    /// inside the identity editor — this makes it discoverable); guests keep the tier
    /// shield, since there's no profile row to hang an avatar on before sign-in.
    private var avatarBadge: some View {
        Button {
            if auth.isSignedIn { showIdentityEditor = true }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if auth.isSignedIn {
                        AvatarView(avatar: container.identity.avatar, size: 84,
                                  background: Color.onAccent.opacity(0.14))
                    } else {
                        Image(systemName: tier.symbol)
                            .font(.system(size: 36, weight: .black))
                            .foregroundStyle(tier.color)
                            .frame(width: 84, height: 84)
                            .background(Color.onAccent.opacity(0.14))
                            .clipShape(Circle())
                    }
                }
                .overlay(Circle().strokeBorder(tier.color, lineWidth: 3.5))
                if auth.isSignedIn {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .padding(6)
                        .background(Color.surface)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.borderInk, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }
        }
        .buttonStyle(PrimePressStyle())
        .disabled(!auth.isSignedIn)
        .accessibilityLabel(auth.isSignedIn ? "Edit avatar and username" : "\(tier.name) tier")
    }

    /// `@username` under the avatar, once identity is claimed. Edit entry point is the
    /// avatar badge's pencil above — a second pencil here read as a duplicate affordance.
    private func identityLine(username: String) -> some View {
        Text("@\(username)")
            .font(.custom(FontName.condBlack, size: 16))
            .foregroundStyle(Color.onAccent)
    }

    /// The all-time-best daily streak, computed straight off the career log rather than a
    /// separately-tracked field — `container.streak` already gives the current one.
    private var bestStreak: Int { CareerStatsMath.longestDailyStreak(careerRows.map(\.playedAt)) }

    private var statRow: some View {
        HStack(spacing: 16) {
            stat("PERFECTS", "\(careerSummary.perfects)")
            Divider().frame(height: 32)
            stat("STREAK", "\(container.streak)", caption: bestStreak > container.streak ? "best \(bestStreak)" : nil)
            Divider().frame(height: 32)
            stat("DAYS PLAYED", "\(careerSummary.days)")
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface()
    }

    private func stat(_ label: String, _ value: String, caption: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
            Text(value).font(.hero(26)).foregroundStyle(Color.textPrimary)
            if let caption {
                Text(caption).font(.label11).foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Highlight reel (career fun facts)

    /// A compact, horizontally-scrolling slice of `StatCatalog`'s ~30 cards — Profile can't show
    /// all of them (that's the Career screen's job), but a taste of the delight surface belongs
    /// right under the headline stats. `StatCatalog.highlights` already gates on `isUnlocked`, so
    /// a 1-game account naturally sees nothing here rather than a wall of "—" placeholders.
    @ViewBuilder
    private var highlightReel: some View {
        let cards = StatCatalog.highlights(careerRows, limit: 5)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("HIGHLIGHTS").font(.label12).foregroundStyle(Color.textMuted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            highlightTile(card, fill: highlightFill(index))
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface()
        }
    }

    private func highlightFill(_ index: Int) -> Color {
        switch index % 3 {
        case 0: return .accentFill
        case 1: return .voltFill
        default: return .goldFill
        }
    }

    private func highlightTile(_ card: StatCard, fill: Color) -> some View {
        let onColor: Color = fill == .accentFill ? .onAccent : (fill == .voltFill ? .onVolt : .onGold)
        return VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.label11).foregroundStyle(onColor.opacity(0.75))
            Text(card.value).font(.hero(22)).foregroundStyle(onColor)
            if let context = card.context {
                Text(context).font(.label11).foregroundStyle(onColor.opacity(0.75))
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(14)
        .blockCard(fill: fill)
    }

    // MARK: - Season badges (M5 Phase F — end-of-season peak-tier reward)

    /// Earned rating-season badges: one pill per closed season/sport showing the peak tier reached.
    /// Legend badges wear the Balatro foil shimmer, matching the rank hero's "one rare card" motif.
    private var seasonBadgesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SEASON BADGES").font(.label12).foregroundStyle(Color.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(container.seasonBadges) { badge in seasonBadgePill(badge) }
                }
                .padding(.horizontal, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private func seasonBadgePill(_ badge: SeasonBadge) -> some View {
        let tier = badge.tier
        return VStack(spacing: 4) {
            Image(systemName: tier.symbol)
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(tier.onColor)
            Text(tier.name.uppercased())
                .font(.label11).foregroundStyle(tier.onColor)
            Text(badge.sport.uppercased())
                .font(.label11).foregroundStyle(tier.onColor.opacity(0.75))
        }
        .frame(width: 76, height: 76)
        .blockCard(fill: tier.color)
        .foil(active: tier == .legend, cornerRadius: Radius.card)
    }

    // MARK: - Ratings (per sport) — demoted to a single summary row; full ladder lives in
    // `RatingLadderView`. Leagues/Versus/season badges still key off `RatingEngine` underneath,
    // this only changes what Profile leads with.

    private var ratingsCard: some View {
        Button { showRatingLadder = true } label: {
            HStack(spacing: 12) {
                Image(systemName: tier.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(tier.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rating").font(.title).foregroundStyle(Color.textPrimary)
                    Text("\(tier.name.uppercased()) \(rating) · VIEW ALL SPORTS")
                        .font(.label11).foregroundStyle(Color.textMuted)
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

                deleteAccountButton
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

                // Hidden rather than shown-and-broken while no iOS OAuth client exists: a
                // sign-in button that always errors is worse than one absent option, and a
                // reviewer tapping it would be looking at a Guideline 2.1 bug. Sign in with
                // Apple covers account creation on its own.
                if GoogleSignIn.isConfigured {
                Button {
                    Task {
                        do {
                            try await container.auth.signInWithGoogle()
                        } catch {
                            // Was `try?`, which is why a rejected token looked like the button
                            // did nothing at all: the flow completed, GoTrue 400'd, and the
                            // error went straight in the bin. A sign-in that fails has to say so.
                            if !(error is CancellationError) {
                                signInError = String(localized: "Couldn't complete sign-in. Try again.")
                            }
                            return
                        }
                        await container.syncIfSignedIn()
                        if container.isSignedIn {
                            container.track(.signInCompleted, ["provider": "google", "surface": "profile"])
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        GoogleGMark(size: 17)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    /// App Store Guideline 5.1.1(v): an app that supports account creation must offer account
    /// deletion in-app. Deliberately styled *below* and weaker than SIGN OUT — outline rather
    /// than filled — because the two sit next to each other and only one of them is permanent.
    ///
    /// One confirmation step, no support channel: Apple allows confirmation but forbids making
    /// the user email or call anyone to finish (outside highly-regulated industries).
    @ViewBuilder
    private var deleteAccountButton: some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            HStack(spacing: 8) {
                if isDeleting { ProgressView().tint(Color.dangerText) }
                Text(isDeleting ? "DELETING…" : "DELETE ACCOUNT")
                    .font(.heading).foregroundStyle(Color.dangerText)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(Color.dangerText.opacity(0.5), lineWidth: 2))
        }
        .buttonStyle(PrimePressStyle())
        .disabled(isDeleting)
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes your account and everything in it — your rating, "
                 + "streak, XP, friends, and any puzzles you've created. This can't be undone.")
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await container.deleteAccount()
            deletionConfirmed = true
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let authorization) = result,
              let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let raw = currentNonce else { return }
        Task {
            try? await container.auth.signInWithApple(
                identityToken: token, rawNonce: raw,
                authorizationCode: cred.authorizationCode
                    .flatMap { String(data: $0, encoding: .utf8) })
            await container.syncIfSignedIn()
            if container.isSignedIn {
                container.track(.signInCompleted, ["provider": "apple", "surface": "profile"])
            }
        }
    }
}
