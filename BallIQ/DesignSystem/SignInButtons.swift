import SwiftUI
import AuthenticationServices

/// Sign in with Apple + Continue with Google, with the whole nonce/token/sync/track dance behind
/// them. The one place provider sign-in is wired from.
///
/// **Why this is shared rather than written per screen.** It was written twice —
/// `OnboardingView.authButtons` and `ProfileView.accountCard` — and the two copies had already
/// drifted in a way that mattered: Profile's Apple path swallowed every failure with `try?`, so a
/// rejected token looked exactly like the button doing nothing. That is verbatim the bug its own
/// Google path carries a comment about having fixed ("a sign-in that fails has to say so"), left
/// standing in the sibling branch six lines away. A third copy for `MomentSheet` would have made
/// three. See AGENTS.md §4.
///
/// Call sites keep their own presentation of failure (Onboarding shows an inline `Text`, Profile
/// raises an alert) via `onError`, and their own idea of what happens next via `onSignedIn` —
/// those are genuinely per-screen. Everything above them is not.
struct SignInButtons: View {
    /// Lands in `sign_in_completed.properties->>'surface'` — which screen converted this account.
    let surface: String
    /// Control height. Onboarding runs 52, Profile 50; carried as a parameter purely so the
    /// extraction doesn't quietly restyle two shipped screens.
    var height: CGFloat = 52
    /// Gap between the two provider buttons. Onboarding's old copy sat them 14 apart, Profile's
    /// 12 (its card's own `spacing`); carried for the same reason as `height` — the extraction
    /// must not re-pace two shipped screens.
    var spacing: CGFloat = 14
    /// Presentation of a failed sign-in. Never called for a user cancellation — that isn't an
    /// error, and an alert on "changed my mind" reads as a bug.
    var onError: (String) -> Void = { _ in }
    /// Runs after a successful sign-in *and* the profile sync that follows it, so
    /// `container.identity` is populated by the time it fires (which is what lets Onboarding and
    /// `MomentSheet` decide whether a username still needs claiming).
    var onSignedIn: () -> Void = { }

    @EnvironmentObject private var container: RepositoryContainer
    @State private var currentNonce: String?

    var body: some View {
        VStack(spacing: spacing) {
            SignInWithAppleButton(.signIn) { request in
                let raw = AuthService.makeNonce()
                currentNonce = raw
                request.requestedScopes = [.fullName, .email]
                request.nonce = AuthService.sha256(raw)
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            // Hidden rather than shown-and-broken while no iOS OAuth client exists (see
            // `GoogleSignIn.clientID`): a button that always errors is worse than one fewer
            // option, and a reviewer tapping it is looking at a Guideline 2.1 bug. Sign in with
            // Apple covers account creation on its own.
            if GoogleSignIn.isConfigured { googleButton }
        }
    }

    private var googleButton: some View {
        Button {
            Task { await signInWithGoogle() }
        } label: {
            HStack(spacing: 8) {
                GoogleGMark(size: 17)
                Text("Continue with Google").font(.bodyStrong)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func signInWithGoogle() async {
        do {
            try await container.auth.signInWithGoogle()
        } catch {
            // A cancelled OAuth browser session is a decision, not a failure.
            if !(error is CancellationError) { onError(Self.failureMessage) }
            return
        }
        await finishSignIn(provider: "google")
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let raw = currentNonce else {
                onError(String(localized: "Sign-in didn't return an identity token. Try again."))
                return
            }
            Task {
                do {
                    try await container.auth.signInWithApple(
                        identityToken: token, rawNonce: raw,
                        authorizationCode: cred.authorizationCode
                            .flatMap { String(data: $0, encoding: .utf8) })
                } catch {
                    onError(Self.failureMessage)
                    return
                }
                await finishSignIn(provider: "apple")
            }
        case .failure:
            // Cancelled at Apple's own sheet, or it failed there. No error noise for a cancel.
            break
        }
    }

    /// Sync first, *then* report and hand back: every caller's follow-up (claim a username, close
    /// a moment) reads `container.identity`, which only exists after the pull.
    private func finishSignIn(provider: String) async {
        await container.syncIfSignedIn()
        guard container.isSignedIn else {
            onError(Self.failureMessage)
            return
        }
        container.track(.signInCompleted, ["provider": provider, "surface": surface])
        onSignedIn()
    }

    private static var failureMessage: String {
        String(localized: "Couldn't complete sign-in. Try again.")
    }
}
