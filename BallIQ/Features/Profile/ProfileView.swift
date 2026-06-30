import SwiftUI
import AuthenticationServices

struct ProfileView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var currentNonce: String?

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
                    heroCard
                    statRow
                    ratingsCard
                    accountCard
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Wordmark() } }
        }
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
                .buttonStyle(.plain)
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
        }
    }
}
