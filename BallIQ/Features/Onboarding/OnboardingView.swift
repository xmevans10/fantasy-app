import SwiftUI
import AuthenticationServices

/// First run, reordered around a first win instead of a first account.
///
/// It used to be one screen: a pitch naming four daily formats, with Sign in with Apple as the
/// visually primary action and "Continue as guest" as a muted link under it. That asks a player
/// with zero investment to make the highest-friction decision in the app (identity) before
/// anything has proved worth signing in *for*, and it names formats — K4C4, Who Am I?, The Grid,
/// Daily Draft — that mean nothing yet.
///
/// The flow is now: pick a sport (the one question a new player can actually answer) → learn the
/// one game in three lines while today's puzzle loads behind it → play it → *then* the account
/// ask, framed against the streak they just earned. Nothing here is gated: daily puzzles are
/// free in every sport, so the first game always exists.
struct OnboardingView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    /// Persisted, not `@State`: the first game runs in a fullScreenCover, and an app switch or a
    /// kill mid-puzzle used to drop the player back at the top of the pitch. Resuming at the
    /// step they left is also what keeps the funnel's step events honest about where people stop.
    @AppStorage("onboardingStep") private var stepRaw = OnboardingStep.sport.rawValue

    @State private var currentNonce: String?
    @State private var error: String?
    /// Gates the post-sign-in username claim prompt (M20): a brand-new account has no
    /// `profiles.username` yet, so we interrupt onboarding once with `IdentityEditorSheet`
    /// instead of leaving username claim buried in Profile where most people never find it.
    /// Claiming is skippable — the sheet dismisses on save *or* cancel, either way we
    /// proceed to `finish()`.
    @State private var showIdentityClaim = false
    /// Today's daily for the chosen sport, fetched while the how-it-works screen is on show so
    /// the PLAY tap opens an already-loaded board rather than a spinner.
    @State private var firstPuzzle: Keep4Puzzle?
    @State private var puzzleLoadFinished = false
    @State private var showFirstGame = false
    /// A PLAY tap that landed while today's puzzle was still in flight. On a cold cache the
    /// fetch measured >7s on a clean simulator install, and a dead primary button on the second
    /// screen of onboarding is worse than a wait — so the tap is queued instead of ignored.
    @State private var pendingPlay = false
    /// The step whose `onboarding_step_viewed` row has already been written — see the `.task`.
    @State private var trackedStep: String?

    private var step: OnboardingStep { OnboardingStep(rawValue: stepRaw) ?? .sport }

    /// Scrolls when the content overflows, sits at the top when it doesn't.
    ///
    /// Deliberately a *bare* `ScrollView` with no measuring container around it. The steps used
    /// `ViewThatFits(in: .vertical)` to get "centered when it fits, scrolling when it doesn't",
    /// and on iPad that rendered a **ghost copy** of each step's secondary button ("Skip for
    /// now", "Not now") — clipped, at the very top of the screen, on every onboarding page.
    /// Reproduced on iPad Air 11-inch, the device class App Review tests on; never on any iPhone
    /// size, which is why it shipped.
    ///
    /// Bisected 2026-07-28, and the result is worth recording because the obvious conclusion is
    /// wrong: the trigger is **any layout-negotiating container**, not `ViewThatFits` as such.
    /// Replacing it with a bare `ScrollView` removed the ghost; re-introducing the same layout
    /// via `GeometryReader { ScrollView { content.frame(minHeight: proxy.size.height) } }` —
    /// the textbook centre-or-scroll idiom — brought it straight back. Both containers render a
    /// measurement pass that iPad makes visible here.
    ///
    /// So the centering is given up on purpose. On iPhone the content nearly fills the screen,
    /// so top-aligned and centered are close to indistinguishable; on iPad the previous centered
    /// layout left a large gap anyway. A visible duplicate button on the first screen of a
    /// reviewed build is a worse trade than slightly higher content.
    private func fitsOrScrolls<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        ScrollView {
            content().frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    var body: some View {
        // The ZStack is a stable container so the cover/sheet/task modifiers below attach once.
        // Hung directly off the `Group`, they attach to whichever step is showing and re-run
        // mid-transition — that is what wrote duplicate `onboarding_step_viewed` rows, and it
        // would put the first game's cover on a view that's being replaced.
        ZStack {
            Group {
                switch step {
                case .sport:     sportStep
                case .howToPlay: howToPlayStep
                case .account:   accountStep
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .animation(Motion.easeOut, value: stepRaw)
        .fullScreenCover(isPresented: $showFirstGame, onDismiss: finishFirstGame) {
            if let firstPuzzle {
                Keep4GameView(puzzle: firstPuzzle).environmentObject(container)
            }
        }
        .sheet(isPresented: $showIdentityClaim, onDismiss: finish) {
            IdentityEditorSheet().environmentObject(container)
        }
        // Belt-and-braces with the ZStack above: a re-run of this task for a step already logged
        // must not write a second row (duplicates were seen in production `events`, 2026-07-27).
        .task(id: stepRaw) {
            guard trackedStep != stepRaw else { return }
            trackedStep = stepRaw
            container.track(.onboardingStepViewed, ["step": step.rawValue, "index": "\(step.index)"])
        }
        .onAppear {
            if let forced = DebugLaunch.onboardingStep { stepRaw = forced }
        }
    }

    // MARK: - Step 1 — sport

    /// Five sports, one tap, no lock badges: every sport's *daily* puzzle is free (only the
    /// arcade setup screens gate MLB/soccer/tennis behind Pro), so a lock here would be both
    /// wrong about the next screen and a paywall in the first ten seconds.
    /// `fitsOrScrolls` rather than an unconditional `ScrollView`: at five sports the whole step
    /// fits and should sit centered, but the layout still has to survive an SE-class screen (the
    /// constraint the old single-screen pitch handled with a `compact` flag) and a sixth sport.
    private var sportStep: some View {
        fitsOrScrolls { sportStepContent }
    }

    private var sportStepContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Wordmark(size: 44)
                Text("WHICH SPORT DO YOU KNOW BEST?")
                    .font(.display1)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
            .heroReveal(0)

            VStack(spacing: 10) {
                ForEach(Array(Sport.allCases.enumerated()), id: \.element) { i, sport in
                    sportRow(sport, volt: i.isMultiple(of: 2) == false)
                }
            }
            .heroReveal(1)

            Text("Every sport stays playable — this just picks where you start.")
                .font(.label12)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .heroReveal(2)
        }
    }

    private func sportRow(_ sport: Sport, volt: Bool) -> some View {
        Button {
            Haptics.tap()
            choose(sport)
        } label: {
            HStack(spacing: 14) {
                sportSticker(sport, volt: volt)
                Text(sport.displayName.uppercased())
                    .font(.title)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .cardSurface()
        }
        .buttonStyle(PrimePressStyle())
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

    /// The pick is written straight to `container.sportFilter` — the same value Home's daily
    /// pager opens on — so the one question we asked visibly pays off on the next screen. It's
    /// written even for a Pro-locked sport, because the dailies it selects are free; the arcade
    /// setup screens have their own guard (`GameSetupScreen.correctLockedDefault`).
    private func choose(_ sport: Sport) {
        container.sportFilter = SportFilter(rawValue: sport.rawValue) ?? .all
        stepRaw = OnboardingStep.howToPlay.rawValue
    }

    // MARK: - Step 2 — how it works (and the puzzle fetch)

    private var howToPlayStep: some View {
        VStack(spacing: 0) {
            // Same fits-or-scrolls treatment as the sport step, with the CTA pinned below it so
            // the thing to tap never moves between the two layouts.
            fitsOrScrolls { howToPlayContent }
                .frame(maxHeight: .infinity)

            VStack(spacing: 12) {
                Button { startFirstGame() } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 8) {
                            if !puzzleLoadFinished {
                                ProgressView().tint(Color.onAccent)
                            }
                            Text(primaryLabel)
                                .font(.custom(FontName.condBlack, size: 18))
                        }
                        if let theme = firstPuzzle?.theme {
                            Text(theme)
                                .font(.label11)
                                .lineLimit(1)
                                .opacity(0.8)
                        }
                    }
                    .foregroundStyle(Color.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PrimePressStyle())

                Button { advanceToAccount() } label: {
                    Text("Skip for now")
                        .font(.bodyStrong)
                        .foregroundStyle(Color.textMuted)
                }
            }
            .heroReveal(1)
        }
        .task { await loadFirstPuzzle() }
    }

    private var howToPlayContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("K4C4")
                    .font(.hero(46))
                    .foregroundStyle(Color.accentText)
                Text("KEEP 4, CUT 4")
                    .font(.display1)
                    .foregroundStyle(Color.textPrimary)
            }
            VStack(alignment: .leading, spacing: 14) {
                ruleRow(1, "Eight real seasons, dealt one card at a time.")
                ruleRow(2, "Keep the four you think scored the most fantasy points.")
                ruleRow(3, "Every call is final. Score 8/8 for a perfect round.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockCard()
        }
        .heroReveal(0)
    }

    /// Reads as a load state, then a promise, then an escape hatch — a thin sport on a day with
    /// no minted board still has to lead somewhere, and dumping the player on Home with no
    /// explanation is worse than a plain CONTINUE.
    private var primaryLabel: LocalizedStringKey {
        if firstPuzzle != nil { return "PLAY TODAY'S PUZZLE" }
        return puzzleLoadFinished ? "CONTINUE" : "LOADING TODAY'S PUZZLE…"
    }

    private func ruleRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.custom(FontName.condBlack, size: 15))
                .foregroundStyle(Color.onAccent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.borderInk, lineWidth: 2)
                )
            Text(text)
                .font(.body14)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadFirstPuzzle() async {
        guard firstPuzzle == nil, !puzzleLoadFinished else { return }
        let filter = container.sportFilter
        var pick = await container.puzzles.keep4Puzzle(for: filter, date: Date())
        // A sport whose pool is thin enough to miss a day still gets a first game — the
        // cross-sport pool always resolves to something.
        if pick == nil, filter != .all {
            pick = await container.puzzles.keep4Puzzle(for: .all, date: Date())
        }
        firstPuzzle = pick?.content
        puzzleLoadFinished = true
        // Combination flag, same idiom as `-screenshotBrowse -screenshotShare`: the guided first
        // game can only be reached through a tap simctl can't perform, so
        // `-screenshotOnboardingStep how_to_play -screenshotGame` drives it (add
        // `-screenshotResult` for the win state).
        if DebugLaunch.autoOpenGame || pendingPlay { startFirstGame() }
    }

    private func startFirstGame() {
        Haptics.tap()
        guard puzzleLoadFinished else { pendingPlay = true; return }
        guard let puzzle = firstPuzzle else { advanceToAccount(); return }
        ActivationMilestone.noteFirstGameStarted(container, format: "keep4",
                                                 sport: puzzle.sport, surface: "onboarding")
        showFirstGame = true
    }

    /// The cover's dismissal is the only signal we get back from the game view, so the win is
    /// read from progress rather than a callback — `hasCompletedToday(puzzleID:)` is true only
    /// if this exact puzzle was actually finished, so quitting the board mid-round correctly
    /// records a start with no completion.
    private func finishFirstGame() {
        if let puzzle = firstPuzzle, container.hasCompletedToday(puzzleID: puzzle.id) {
            ActivationMilestone.noteFirstGameCompleted(container, format: "keep4",
                                                       sport: puzzle.sport, surface: "onboarding")
        }
        advanceToAccount()
    }

    private func advanceToAccount() {
        stepRaw = OnboardingStep.account.rawValue
    }

    // MARK: - Step 3 — account (after the first game, not before it)

    private var accountStep: some View {
        VStack(spacing: 0) {
            fitsOrScrolls { accountPitch }
                .frame(maxHeight: .infinity)

            authButtons.heroReveal(1)
        }
    }

    private var accountPitch: some View {
        VStack(spacing: 18) {
            if container.streak > 0 { streakBadge }
            Text("KEEP WHAT YOU JUST EARNED")
                .font(.display1)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text("Your streak, rating and league spot live on your account — sign in and they follow you to any device.")
                .font(.body14)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .heroReveal(0)
    }

    /// The reason to sign in, stated as a number the player just produced rather than a promise.
    private var streakBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(Color.onWarning)
            Text(container.streak == 1 ? "1 DAY STREAK" : "\(container.streak) DAY STREAK")
                .font(.title)
                .foregroundStyle(Color.onWarning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .blockCard(fill: .warningFill)
    }

    private var authButtons: some View {
        VStack(spacing: 14) {
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
                Text("Not now")
                    .font(.bodyStrong)
                    .foregroundStyle(Color.textMuted)
            }

            if let error {
                Text(error).font(.label12).foregroundStyle(Color.dangerText)
            }
        }
    }

    private var googleButton: some View {
        Button {
            Task { await signInWithGoogle() }
        } label: {
            HStack(spacing: 8) {
                GoogleGMark(size: 18)
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
            finishOrClaimUsername()
        } catch {
            self.error = String(localized: "Couldn't complete sign-in. Try again.")
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let raw = currentNonce else {
                error = String(localized: "Sign-in didn't return an identity token. Try again.")
                return
            }
            Task {
                do {
                    try await container.auth.signInWithApple(
                        identityToken: token, rawNonce: raw,
                        authorizationCode: cred.authorizationCode
                            .flatMap { String(data: $0, encoding: .utf8) })
                    await container.syncIfSignedIn()
                    container.track(.signInCompleted, ["provider": "apple", "surface": "onboarding"])
                    finishOrClaimUsername()
                } catch {
                    self.error = String(localized: "Couldn't complete sign-in. Try again.")
                }
            }
        case .failure:
            // User canceled or it failed — stay on the screen, no error noise for cancel.
            break
        }
    }

    /// Called right after `syncIfSignedIn()` populates `container.identity` from either
    /// sign-in path. A returning user (already has a username) skips straight to `finish()`
    /// as before; a brand-new account gets one shot at claiming a username before landing
    /// in the app — `finish()` itself is deferred to the sheet's `onDismiss`.
    private func finishOrClaimUsername() {
        if container.identity.username == nil {
            showIdentityClaim = true
        } else {
            finish()
        }
    }

    /// No longer resets `container.sportFilter` to `.all` — the sport step wrote a deliberate
    /// choice into it, and Home's daily pager is the payoff for having asked.
    private func finish() {
        container.track(.onboardingCompleted, ["signed_in": "\(container.isSignedIn)"])
        hasOnboarded = true
    }
}

private extension OnboardingStep {
    /// Position in the flow, carried on the step event so a warehouse query can order the funnel
    /// without hardcoding the step names in SQL.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
