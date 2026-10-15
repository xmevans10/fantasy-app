import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Tab switch out of Profile — lets the empty-state CTA ("Play a puzzle on Home") be a
    /// working button. Defaulted so `ProfileView()` (tests, previews) keeps compiling.
    var selectedTab: Binding<Int> = .constant(0)

    @State private var notificationSettings = NotificationSettings.allEnabled
    @State private var showCareer = false
    @State private var showSettings = false
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

    init(selectedTab: Binding<Int> = .constant(0), initialSettings: Bool = false) {
        self.selectedTab = selectedTab
        _showSettings = State(initialValue: initialSettings)
    }

    /// Strongest sport for the optional share card (ties favor NFL).
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
                    heroCard
                    VStack(spacing: 0) {
                        careerRow
                        Divider().padding(.horizontal, 16)
                        ratingsCard
                        if auth.isSignedIn {
                            Divider().padding(.horizontal, 16)
                            friendsRow
                        }
                    }.cardSurface()
                    if !container.seasonBadges.isEmpty { seasonBadgesCard }
                    if !auth.isSignedIn { accountCard }
                }
                .padding(16)
            }
            .paperGround()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Wordmark.toolbarItem()
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }.labelStyle(.iconOnly)
                }
            }
            .navigationDestination(isPresented: $showSettings) { settingsView }
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
            if DebugLaunch.autoOpenProfileSettings { showSettings = true }
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
                    Text("Stats, records & highlights").font(.label11).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
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
                    Text("Requests & challenges").font(.label11).foregroundStyle(Color.textMuted)
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
            Label("Share profile", systemImage: "square.and.arrow.up").font(.bodyStrong)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardSurface()
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
            notificationToggle("Nudges & recaps", \.engagement)
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
        let progress = LevelCurve.progress(forXP: container.xp)
        let identityLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return VStack(alignment: .leading, spacing: 14) {
            identityLayout {
                avatarBadge
                VStack(alignment: .leading, spacing: 4) {
                    Text(auth.isSignedIn ? container.identity.username.map { "@" + $0 } ?? "Your profile" : "Your profile")
                        .font(.display(28)).foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            Text("Level \(progress.level)")
                            Text(LevelCurve.title(for: progress.level))
                        } else {
                            Text("Level \(progress.level) · \(LevelCurve.title(for: progress.level))")
                        }
                    }.font(.body14).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ProgressView(value: Double(progress.intoLevel), total: Double(progress.span))
                .tint(Color.accentFill)
                .accessibilityLabel("Progress to level \(progress.level + 1)")
                .accessibilityValue("\(progress.intoLevel) of \(progress.span) XP")
            Text("\(progress.span - progress.intoLevel) XP to level \(progress.level + 1)")
                .font(.label12).foregroundStyle(Color.textSecondary)
            if auth.isSignedIn && container.identity.username == nil {
                Button("Choose a username") { showIdentityEditor = true }.font(.bodyStrong)
            }
            if careerRows.isEmpty {
                Text("Your first puzzle starts your career.").font(.body14).foregroundStyle(Color.textSecondary)
                Button("Play a puzzle", systemImage: "arrow.right") { selectedTab.wrappedValue = 0 }
                    .font(.bodyStrong).buttonStyle(.borderedProminent).tint(Color.accentFill)
            } else {
                Divider()
                statRow
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).cardSurface()
    }

    private var settingsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if auth.isSignedIn {
                    if container.identity.username != nil { shareCardRow }
                    favoriteTeamsCard
                    notificationsCard
                }
                if container.isAdmin { moderationRow }
                accountCard
            }.padding(16)
        }.paperGround().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }

    /// Compact identity with one edit entry; a guest does not wear an unearned rank.
    private var avatarBadge: some View {
        Button {
            if auth.isSignedIn { showIdentityEditor = true }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if auth.isSignedIn {
                        AvatarView(avatar: container.identity.avatar, size: 56,
                                  background: Color.accentBg)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(Color.accentText)
                            .frame(width: 56, height: 56)
                            .background(Color.accentBg)
                            .clipShape(Circle())
                    }
                }
                .overlay(Circle().strokeBorder(Color.borderStrong, lineWidth: 1))
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
        .accessibilityLabel(auth.isSignedIn ? "Edit avatar and username" : "Profile avatar")
    }

    private var statRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    statLine("Games", "\(careerSummary.games)")
                    if let accuracy = careerSummary.accuracy { statLine("Accuracy", "\(Int((accuracy * 100).rounded()))%") }
                    statLine("Streak", "\(container.streak)")
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    stat("GAMES", "\(careerSummary.games)")
                    if let accuracy = careerSummary.accuracy { stat("ACCURACY", "\(Int((accuracy * 100).rounded()))%") }
                    stat("STREAK", "\(container.streak)")
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.hero(28)).foregroundStyle(Color.textPrimary)
            Text(label).font(.label11).foregroundStyle(Color.textMuted)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.body14)
            Spacer(minLength: 12)
            Text(value).font(.heading).fixedSize()
        }.accessibilityElement(children: .combine)
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
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rating").font(.title).foregroundStyle(Color.textPrimary)
                    Text("Ratings across all sports")
                        .font(.label11).foregroundStyle(Color.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
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
                    Text("Signed in. Progress syncs across devices")
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
                // Was a hand-rolled copy of `OnboardingView`'s block, and the two had drifted:
                // this one's *Apple* path swallowed every failure with `try?` — the exact bug its
                // own Google path six lines below carried a comment about having fixed. Both now
                // route through `SignInButtons`, which reports either provider's failure.
                SignInButtons(surface: "profile", height: 50, spacing: 12,
                              onError: { signInError = $0 })
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
            Text("This permanently deletes your account and everything in it, your rating, "
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

}
