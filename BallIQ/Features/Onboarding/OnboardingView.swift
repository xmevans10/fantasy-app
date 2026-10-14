import SwiftUI

/// First run, reordered around a first win instead of a first account.
///
/// It used to be one screen: a pitch naming four daily formats, with Sign in with Apple as the
/// visually primary action and "Continue as guest" as a muted link under it. That asks a player
/// with zero investment to make the highest-friction decision in the app (identity) before
/// anything has proved worth signing in *for*, and it names formats — K4C4, Who Am I?, The Grid,
/// Daily Draft — that mean nothing yet.
///
/// The flow is now: what Playbook is, with a flippable deck of every mode → pick a sport (the one
/// question a new player can actually answer) → make one practice keep/cut call while today's
/// puzzle loads behind it → play it → *then* the account ask, framed against the streak they
/// just earned and the rating they can build. Nothing here is gated: daily puzzles are free
/// in every sport, so the first game always exists.
struct OnboardingView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    /// Persisted, not `@State`: the first game runs in a fullScreenCover, and an app switch or a
    /// kill mid-puzzle used to drop the player back at the top of the pitch. Resuming at the
    /// step they left is also what keeps the funnel's step events honest about where people stop.
    @AppStorage("onboardingStep") private var stepRaw = OnboardingStep.welcome.rawValue

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
    /// The sport tile that was just tapped, held for the half-second pop before advancing.
    @State private var pickedSport: Sport?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: OnboardingStep { OnboardingStep(rawValue: stepRaw) ?? .welcome }

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
            VStack(spacing: 12) {
                OnboardingProgress(current: step.index, total: OnboardingStep.allCases.count)
                Group {
                    switch step {
                    case .welcome:
                        OnboardingWelcomeStep { go(.modes) }
                    case .modes:
                        OnboardingModesStep { go(.sport) }
                    case .sport:     sportStep
                    case .howToPlay: howToPlayStep
                    case .account:   accountStep
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .id(stepRaw)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .slideBackdrop(step.tint)
        .animation(Motion.overshoot, value: stepRaw)
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
        VStack(spacing: 22) {
            // Over the orange backdrop block, so white, not ink.
            VStack(spacing: 0) {
                Text("PICK YOUR")
                    .font(.custom(FontName.condBlack, size: 24))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text("SPORT")
                    .font(.hero(72))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.borderInk, radius: 0, x: 4, y: 4)
                Text("Every sport stays playable. This just picks where you start.")
                    .font(.label12)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .heroReveal(0)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(Array(Sport.released.enumerated()), id: \.element) { i, sport in
                    sportTile(sport, palette: Self.tilePalette[i % Self.tilePalette.count])
                        .heroReveal(1 + i / 2)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    /// Fill/on pairs cycled across the tiles so the grid reads as a sticker sheet, not a list.
    private static let tilePalette: [(fill: Color, on: Color)] = [
        (.accentFill, .onAccent), (.voltFill, .onVolt), (.proFill, .onPro),
        (.successFill, .onSuccess), (.dangerFill, .onDanger), (.goldFill, .onGold),
    ]

    /// A tap pops the tile and stamps it before moving on. The short hold is the point: an
    /// instant jump to the next slide makes the choice feel like it didn't register.
    private func sportTile(_ sport: Sport, palette: (fill: Color, on: Color)) -> some View {
        let picked = pickedSport == sport
        return Button {
            guard pickedSport == nil else { return }
            Haptics.success()
            withAnimation(Motion.overshoot) { pickedSport = sport }
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.55)) {
                choose(sport)
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: sport.symbol)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(palette.fill)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(palette.on))
                    .overlay(Circle().strokeBorder(Color.borderInk, lineWidth: 2.5))
                    .rotationEffect(.degrees(picked ? -12 : 0))
                Text(sport.displayName.uppercased())
                    .font(.custom(FontName.condBlack, size: 22))
                    .foregroundStyle(palette.on)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .blockCard(fill: palette.fill)
            .overlay(alignment: .topTrailing) {
                if picked {
                    PopStamp(text: "MY SPORT!", angle: 10, size: 13)
                        .offset(x: 6, y: -10)
                }
            }
            .scaleEffect(picked ? 1.08 : (pickedSport == nil ? 1 : 0.94))
            .opacity(pickedSport == nil || picked ? 1 : 0.55)
        }
        .buttonStyle(PrimePressStyle(scale: 0.94))
        .accessibilityLabel(Text(sport.displayName))
    }

    /// The pick is written straight to `container.sportFilter` — the same value Home's daily
    /// pager opens on — so the one question we asked visibly pays off on the next screen. It's
    /// written even for a Pro-locked sport, because the dailies it selects are free; the arcade
    /// setup screens have their own guard (`GameSetupScreen.correctLockedDefault`).
    private func choose(_ sport: Sport) {
        container.sportFilter = SportFilter(rawValue: sport.rawValue) ?? .all
        go(.howToPlay)
    }

    private func go(_ next: OnboardingStep) {
        stepRaw = next.rawValue
    }

    // MARK: - Step 2 — how it works (and the puzzle fetch)

    private var howToPlayStep: some View {
        VStack(spacing: 0) {
            // Same fits-or-scrolls treatment as the sport step, with the CTA pinned below it so
            // the thing to tap never moves between the two layouts.
            fitsOrScrolls { howToPlayContent }
                .frame(maxHeight: .infinity)

            VStack(spacing: 12) {
                OnboardingCTA(title: primaryLabel, subtitle: firstPuzzle?.theme,
                              loading: !puzzleLoadFinished) { startFirstGame() }

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

    /// One practice card instead of three rule lines: production showed a 60% drop between
    /// picking a sport and starting the first game (HANDOFF-m30), and a rule list is the part of
    /// that screen a new player skims. Making the call once teaches the gesture and the grade
    /// before the real board, while today's puzzle loads behind it.
    private var howToPlayContent: some View {
        OnboardingPracticeCard(sport: Sport(rawValue: container.sportFilter.rawValue) ?? .nfl)
    }

    /// Reads as a load state, then a promise, then an escape hatch — a thin sport on a day with
    /// no minted board still has to lead somewhere, and dumping the player on Home with no
    /// explanation is worse than a plain CONTINUE.
    private var primaryLabel: LocalizedStringKey {
        if firstPuzzle != nil { return "PLAY TODAY'S PUZZLE" }
        return puzzleLoadFinished ? "CONTINUE" : "LOADING TODAY'S PUZZLE…"
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
        // A new player's first board is the one that most needs its photos, and they are still
        // on the sport picker for a few seconds, so warm it now rather than at the gate.
        PuzzleImageWarmer.warm(keep4: firstPuzzle)
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
        go(.account)
    }

    // MARK: - Step 3 — account (after the first game, not before it)

    private var accountStep: some View {
        VStack(spacing: 0) {
            // Same shape as the how-to-play step: content scrolls, auth buttons pinned below.
            // This step used spacers around a `fixedSize` ScrollView to centre a short pitch;
            // the account benefits need room to wrap, and `fixedSize` then
            // pushed the content up under the status bar and "Not now" off the bottom instead
            // of scrolling. Still no measuring container (iPad ghost button — see `fitsOrScrolls`).
            fitsOrScrolls { accountPitch }
                .frame(maxHeight: .infinity)

            authButtons.heroReveal(1)
        }
    }

    /// The three things an account holds, shown rather than named.
    ///
    /// This used to be one sentence — "your streak, rating and league spot live on your account"
    /// — above roughly 800pt of empty screen, which was both the emptiest view in the app and a
    /// weaker argument than the facts allowed. The sentence listed three benefits and evidenced
    /// none of them. The rows below say what each one actually is and what losing it costs, and
    /// they close the gap with the answer to the question the screen is asking.
    ///
    /// Deliberately honest when there is nothing to show: a player who quit mid-board has no
    /// streak, so the badge is absent and the streak row reads as the promise it is rather than
    /// claiming a number they never earned.
    private var accountPitch: some View {
        VStack(spacing: 18) {
            if container.streak > 0 { streakBadge }
            Text("KEEP WHAT YOU JUST EARNED")
                .font(.display1)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)

            VStack(alignment: .leading, spacing: 14) {
                keepRow("flame.fill", "Your streak",
                        container.streak > 0
                            ? "You're on \(container.streak). Reinstall without an account and it starts over at zero."
                            : "Play a day at a time and it builds. Without an account it starts over at zero.")
                keepRow("chart.line.uptrend.xyaxis", "Your rating",
                        "Every ranked game moves it. Signed in, it follows you to any device.")
                keepRow("trophy.fill", "Your league",
                        "You're placed with players at your level every Monday. That needs an account.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockCard()
        }
        .heroReveal(0)
    }

    /// Icon tile plus copy, the same rhythm as the welcome deck's stickers.
    private func keepRow(_ symbol: String, _ title: LocalizedStringKey,
                         _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.borderInk, lineWidth: 2)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(Color.textPrimary)
                Text(detail)
                    .font(.label12)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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

    /// The provider buttons themselves live in `SignInButtons` — the same block was written here
    /// and again in `ProfileView`, and the two had drifted (see that file's note). This screen
    /// keeps what's genuinely its own: the inline error line, the "Not now" escape, and what
    /// happens after a successful sign-in.
    private var authButtons: some View {
        VStack(spacing: 14) {
            SignInButtons(surface: "onboarding",
                          onError: { error = $0 },
                          onSignedIn: finishOrClaimUsername)

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

    /// The colour block behind each slide. One per slide, and a different one each time, so a
    /// tap forward visibly changes the whole screen, not just the text on it.
    var tint: Color {
        switch self {
        case .welcome:   .accentFill
        case .modes:     .proFill
        case .sport:     .warningFill
        case .howToPlay: .dangerFill
        case .account:   .goldFill
        }
    }
}
