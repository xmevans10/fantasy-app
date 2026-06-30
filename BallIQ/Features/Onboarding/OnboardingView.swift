import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var selectedSports: Set<Sport> = [.nfl]
    @State private var currentNonce: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Wordmark(size: 52)
            Text("PROVE YOU KNOW BALL.")
                .font(.display1)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                Text("PICK YOUR SPORTS")
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                HStack(spacing: 10) {
                    ForEach(Sport.allCases) { sport in
                        sportPill(sport)
                    }
                }
            }
            .padding(.top, 8)

            Spacer()

            SignInWithAppleButton(.signIn) { request in
                let raw = AuthService.makeNonce()
                currentNonce = raw
                request.requestedScopes = [.fullName, .email]
                request.nonce = AuthService.sha256(raw)
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            googleButton

            Button { finish() } label: {
                Text("Continue as guest")
                    .font(.bodyStrong)
                    .foregroundStyle(Color.textMuted)
            }

            if let error {
                Text(error).font(.label12).foregroundStyle(Color.dangerText)
            }
            Spacer().frame(height: 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    private var googleButton: some View {
        Button {
            Task { await signInWithGoogle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 16, weight: .bold))
                Text("Continue with Google").font(.bodyStrong)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func signInWithGoogle() async {
        do {
            try await container.auth.signInWithProvider("google")
            await container.syncIfSignedIn()
            finish()
        } catch {
            self.error = "Couldn't complete sign-in. Try again."
        }
    }

    private func sportPill(_ sport: Sport) -> some View {
        let on = selectedSports.contains(sport)
        return Button {
            if on { selectedSports.remove(sport) } else { selectedSports.insert(sport) }
            Haptics.tap()
        } label: {
            Text(sport.displayName)
                .font(.custom(on ? FontName.condBlack : FontName.condBold, size: 16))
                .foregroundStyle(on ? Color.onAccent : Color.textPrimary)
                .padding(.horizontal, 20).padding(.vertical, 11)
                .background(on ? Color.accentFill : Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let raw = currentNonce else {
                error = "Sign-in didn't return an identity token. Try again."
                return
            }
            Task {
                do {
                    try await container.auth.signInWithApple(identityToken: token, rawNonce: raw)
                    await container.syncIfSignedIn()
                    finish()
                } catch {
                    self.error = "Couldn't complete sign-in. Try again."
                }
            }
        case .failure:
            // User canceled or it failed — stay on the screen, no error noise for cancel.
            break
        }
    }

    private func finish() {
        if selectedSports.count == 1, let s = selectedSports.first,
           let filter = SportFilter(rawValue: s.rawValue) {
            container.sportFilter = filter
        } else {
            container.sportFilter = .all
        }
        hasOnboarded = true
    }
}
