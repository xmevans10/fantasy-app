import SwiftUI
import AuthenticationServices

struct ProfileView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var auth: AuthService

    @State private var currentNonce: String?

    private var rating: Int { container.rating(for: .nfl) }
    private var tier: Tier { Tier.forRating(rating) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    statRow
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
            Text("NFL RATING").font(.label12).foregroundStyle(Color.onAccent.opacity(0.75))
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
