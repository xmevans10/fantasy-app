import SwiftUI
import AuthenticationServices

struct ProfileView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var currentNonce: String?
    @State private var notificationSettings = NotificationSettings.allEnabled
    @State private var showStats = false
    @State private var showModeration = false

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
                    heroCard.heroReveal(0)
                    statRow.heroReveal(1)
                    statsRow.heroReveal(2)
                    ratingsCard.heroReveal(3)
                    if auth.isSignedIn { notificationsCard.heroReveal(4) }
                    if container.isAdmin { moderationRow.heroReveal(5) }
                    accountCard.heroReveal(6)
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

    // MARK: - Notifications

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOTIFICATIONS").font(.label12).foregroundStyle(Color.textMuted)
            notificationToggle("Streak at risk", \.streakAtRisk)
            notificationToggle("League position", \.leaguePosition)
            notificationToggle("Versus challenges", \.versusChallenge)
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
