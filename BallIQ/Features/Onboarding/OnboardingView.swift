import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var currentNonce: String?
    @State private var error: String?

    var body: some View {
        // Short screens (iPhone SE class) can't fit the full pitch without clipping the
        // guest button off the bottom, so they keep the sport stickers and drop the
        // feature card rather than scrolling a sign-in screen.
        GeometryReader { geo in
            let compact = geo.size.height < 700
            VStack(spacing: compact ? 20 : 28) {
            Spacer()
            VStack(spacing: 22) {
                Wordmark(size: 52)
                Text("PROVE YOU KNOW BALL.")
                    .font(.display1)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .heroReveal(0)

            valueProps(compact: compact)
                .heroReveal(1)

            Spacer()

            VStack(spacing: 22) {
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
            }
            .heroReveal(2)
            Spacer().frame(height: 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.appBackground)
    }

    /// Fills the space between the hero and the sign-in buttons with a value pitch in the
    /// Prime Time idiom (DESIGN.md): sport "stickers" — color blocks with thick ink outlines
    /// and hard offset shadows, alternating the dominant/accent pair — over one blockCard of
    /// three condensed-caps feature lines. Deliberately loud; no soft pastel chips.
    /// `compact` (short screens) keeps only the stickers so the guest button never clips.
    private func valueProps(compact: Bool) -> some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                ForEach(Array(Sport.allCases.enumerated()), id: \.element) { i, sport in
                    sportSticker(sport, volt: i.isMultiple(of: 2) == false)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Five sports: NFL, NBA, MLB, soccer, and tennis")

            if !compact {
                VStack(alignment: .leading, spacing: 16) {
                    featureRow("bolt.fill", fill: .accentFill, on: .onAccent,
                               "Daily puzzles", "A fresh Keep4 and Who Am I? every day")
                    featureRow("chart.bar.fill", fill: .voltFill, on: .onVolt,
                               "Real seasons", "Rank real careers by the stats, not vibes")
                    featureRow("trophy.fill", fill: .warningFill, on: .onWarning,
                               "Compete", "Leagues, streaks, and 1v1 challenges")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blockCard()
            }
        }
    }

    /// One sport icon as a sticker: accent/volt fill, ink ring, hard ledge shadow.
    private func sportSticker(_ sport: Sport, volt: Bool) -> some View {
        Image(systemName: sport.symbol)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(volt ? Color.onVolt : Color.onAccent)
            .frame(width: 46, height: 46)
            .background(
                ZStack {
                    Circle().fill(Color.borderInk).offset(x: 3, y: 3)
                    Circle().fill(volt ? Color.voltFill : Color.accentFill)
                    Circle().strokeBorder(Color.borderInk, lineWidth: 2.5)
                }
            )
            .accessibilityHidden(true)
    }

    private func featureRow(_ symbol: String, fill: Color, on: Color,
                            _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(on)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.borderInk, lineWidth: 2)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased()).font(.heading).foregroundStyle(Color.textPrimary)
                Text(subtitle).font(.label12).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
            container.track(.signInCompleted, ["provider": "google", "surface": "onboarding"])
            finish()
        } catch {
            self.error = "Couldn't complete sign-in. Try again."
        }
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
                    container.track(.signInCompleted, ["provider": "apple", "surface": "onboarding"])
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
        container.sportFilter = .all
        container.track(.onboardingCompleted, ["signed_in": "\(container.isSignedIn)"])
        hasOnboarded = true
    }
}
