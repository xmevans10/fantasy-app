import SwiftUI
import UserNotifications

struct HomeView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var moments: MomentPresenter
    @Environment(\.scenePhase) private var scenePhase
    /// Root tab selection (0 Home…4 Profile) — the formats grid uses this to jump to the
    /// Versus tab, since Versus is a full tab/repository, not a sheet Home can present itself.
    @Binding var selectedTab: Int
    /// Today's daily K4C4/Who Am I? pick per sport, keyed as pages fill in — see
    /// `loadDaily(for:)`. A missing key means "not fetched yet", not "no puzzle"; `loadedSports`
    /// disambiguates that from a genuine empty result once the fetch resolves.
    @State private var keep4BySport: [Sport: DailyPick<Keep4Puzzle>] = [:]
    @State private var whoAmIBySport: [Sport: DailyPick<WhoAmIPuzzle>] = [:]
    @State private var journeymanBySport: [Sport: DailyPick<JourneymanPuzzle>] = [:]
    @State private var loadedSports: Set<Sport> = []
    /// The local calendar day the maps above were loaded for. iOS keeps the app in memory for
    /// days, so without this the `loadedSports` guard would pin every user to the FIRST day's
    /// puzzles until the process happened to die — the daily loop's cardinal sin (a "daily"
    /// that doesn't change daily). Compared against the current day at every foregrounding and
    /// at the live midnight tick; a mismatch throws the whole cache away and refetches.
    @State private var dailiesDay = PuzzleStore.localDayString()
    /// The sport page currently visible in the daily-games pager. Browsing only — swiping
    /// never writes back to `container.sportFilter` (2026-07-09 decision, see `body` below).
    @State private var dailyPage: Sport = .nfl
    @State private var activePuzzle: Keep4Puzzle?
    @State private var activeWhoAmI: WhoAmIPuzzle?
    @State private var activeJourneyman: JourneymanPuzzle?
    @State private var showBrowse = false
    @State private var showPaywall = false
    /// Home gates two different things behind the same sheet — the archive row and The Grid —
    /// so the trigger has to be carried rather than hardcoded at the presentation site, or
    /// both would report as one surface and the "which gate sells Pro" question stays
    /// unanswerable.
    @State private var paywallTrigger: PaywallTrigger = .other
    @State private var showOverUnder = false
    @State private var showDraftSpin = false
    @State private var showDailyDraft = false
    @State private var showGrid = false
    @State private var showBlitz = false
    /// The K4C4/Who Am I? tiles open their format hub (daily + archive in one place,
    /// 2026-07-17 IA fix) — not just today's daily, which made the flashiest tiles the
    /// shallowest tap on the page.
    @State private var showKeep4Hub = false
    @State private var showWhoAmIHub = false
    @State private var showJourneymanHub = false
    @State private var shareTarget: SharablePuzzle?
    /// Which daily the player just opened. The game runs in a `fullScreenCover(item:)`, whose
    /// `onDismiss` can no longer see the item, so the activation milestone needs the puzzle
    /// stashed alongside it.
    @State private var launchedDaily: LaunchedDaily?
    /// Streak-reminder primer (see `pushPrimerCard`). State rather than a computed property
    /// because deciding it requires an `await` on the system's authorization status.
    @State private var showPushPrimer = false
    @State private var streakRowDismissed = false

    private let gridColumns = [GridItem(.flexible(), spacing: 12),
                               GridItem(.flexible(), spacing: 12)]

    /// Whether Home may show its paid surfaces yet.
    ///
    /// A brand-new player met Pro three times before their first session ended: the `HARD · PRO`
    /// control above card 1 of 8, the archive row here, and the Grid tile below it. None is wrong
    /// to exist; all three are wrong to show to someone with no basis for judging whether the
    /// paid tier fits them. Production bears it out — 258 paywall views against 11 completed
    /// first games, a 23:1 ratio of asking to delivering.
    ///
    /// Held for three games rather than one so the gate outlasts a single curious tap. A player
    /// who already owns Pro sees them immediately: there is nothing to sell, and hiding paid
    /// features from a subscriber would be a worse bug than showing them too early.
    private var showsProSurfaces: Bool {
        container.entitlements.isPro || container.completedGames >= 3
    }

    /// The Grid is the only `isPro` tile, but filtering on the flag rather than naming it keeps
    /// this correct when a second paid format is added.
    private var visibleFormats: [GameFormat] {
        showsProSurfaces ? GameFormat.all : GameFormat.all.filter { !$0.isPro }
    }

    /// Stands in for the rank widget until the rating is real. Says how many boards are left
    /// rather than showing a tier the next game could still move — a new player who saw BRONZE
    /// here on day one was being told their rank before the app had any basis for one.
    private var placementCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "target")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.accentFill))
                .overlay(Circle().strokeBorder(Color.borderInk, lineWidth: 2.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(container.placementRemaining == 1
                     ? String(localized: "1 GAME TO PLACE")
                     : String(localized: "\(container.placementRemaining) GAMES TO PLACE"))
                    .font(.title)
                    .foregroundStyle(Color.textPrimary)
                Text("Your rank appears once your rating starts counting.")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    /// Sport whose rating the rank widget shows — tracks the pager's visible page
    /// (`dailyPage`), not `container.sportFilter`. The section sits directly beneath the
    /// daily-games pager (2026-07-17) precisely so it reads as describing whichever cards are
    /// on screen; following the global filter instead left it stuck on the last sport chosen
    /// on a setup screen, so swiping the pager to NBA could leave the widget reading "MLB
    /// RATING" (verified on a user's screen recording, 2026-07-29). `dailyPage` itself still
    /// never writes back into `sportFilter` — see `body`'s 2026-07-09 note — this only reads it.
    private var rankSport: Sport { dailyPage }

    /// nil when the puzzle hasn't loaded (or failed to) — kept distinct from `false` so a
    /// load failure never gets counted as "completed" by `HomeDailyLoop`. Tracks whichever
    /// sport's page is currently visible in the pager, not necessarily `container.sportFilter`.
    private var keep4CompletedToday: Bool? {
        keep4BySport[dailyPage].map { container.hasCompletedToday(puzzleID: $0.content.id) }
    }
    private var whoAmICompletedToday: Bool? {
        whoAmIBySport[dailyPage].map { container.hasCompletedToday(puzzleID: $0.content.id) }
    }
    private var journeymanCompletedToday: Bool? {
        journeymanBySport[dailyPage].map { container.hasCompletedToday(puzzleID: $0.content.id) }
    }
    private var allDailiesComplete: Bool {
        HomeDailyLoop.allDailiesComplete(keep4CompletedToday, whoAmICompletedToday,
                                         journeymanCompletedToday)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // No sport chips here anymore (2026-07-09): sport is chosen per-game on
                    // each format's own setup screen, which writes the choice back to
                    // `container.sportFilter` so these daily previews follow the last pick.
                    if !streakRowDismissed {
                        HStack {
                            streakRow
                            Spacer()
                            Button {
                                withAnimation(Motion.easeOut) { streakRowDismissed = true }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.textMuted)
                            }
                        }
                        .heroReveal(0)
                    }

                    if showPushPrimer { pushPrimerCard.heroReveal(1) }
                    else if let moment = inlineMoment { momentCard(moment).heroReveal(1) }

                    // Formats first (2026-08-27): the grid is the page's actual menu — every
                    // way to play, arcade included — and it sat below the rank widget and the
                    // archive row, three scrolls down. The dailies below it are the day's
                    // *specific* boards, which read better as "and here's today's" than as the
                    // only thing above the fold.
                    section("Game formats") {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(visibleFormats) { format in
                                FormatGridItem(format: format) { launch(format) }
                            }
                        }
                    }
                    .heroReveal(1)

                    section("Today's daily games") {
                        VStack(spacing: 14) {
                            if allDailiesComplete {
                                // Sells tomorrow instead of leaving the section reading as
                                // "two finished cards and nothing else to do" — the arcade
                                // formats are still fair game today even once the ranked
                                // dailies are done.
                                DailyLoopCountdownCard(streak: container.streak,
                                                       arcadeFormats: GameFormat.arcade,
                                                       launch: launch,
                                                       launchDailyDraft: { launchDraftSpin(daily: true) })
                            }
                            // Still visible (tapping either reopens today's result/recap, same
                            // as before) but visually secondary once the countdown card above
                            // is doing the selling — a dimmed "DONE" pair reads as evidence of
                            // completion, not the next thing to do. Swiping browses every
                            // sport's pair (2026-07-20); it never writes `container.sportFilter`
                            // (2026-07-09: sport is chosen per-game on each format's own setup
                            // screen, not globally) — that's still the only writer.
                            DailyGamesPager(sports: Sport.allCases, selection: $dailyPage) { sport in
                                dailyCardStack(for: sport)
                            }
                            .opacity(allDailiesComplete ? 0.6 : 1)
                        }
                    }
                    .heroReveal(2)

                    // Directly beneath the daily cards that feed it — the rank used to sit at
                    // the very bottom of the page, disconnected from the ranked games above
                    // (user feedback 2026-07-17: "ranked puzzles are not intuitively placed").
                    // During placement the rating hasn't moved yet, and showing a tier off a
                    // provisional number is what produced the contradiction this fixes: Home read
                    // the per-sport rating (BRONZE 990) while Profile read the global one
                    // (SILVER 1,000) in the same session, ninety seconds after install.
                    section(container.isInPlacement ? "Placement" : "Your rank") {
                        if container.isInPlacement {
                            placementCard
                        } else {
                            RankWidget(sport: rankSport, rating: container.rating(for: rankSport))
                        }
                    }
                    .heroReveal(3)

                    // Pro is held back for the first three games — see `showsProSurfaces`.
                    if showsProSurfaces {
                        Button {
                            if container.entitlements.canAccessArchive { showBrowse = true }
                            else { paywallTrigger = .archive; showPaywall = true }
                        } label: { browseRow }
                            .buttonStyle(PrimePressStyle())
                            .heroReveal(4)
                    }

                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("")
            .navigationDestination(isPresented: $showBrowse) {
                BrowseView().environmentObject(container)
            }
            .fullScreenCover(item: $activePuzzle, onDismiss: finishDailyGame) { puzzle in
                Keep4GameView(puzzle: puzzle).environmentObject(container)
            }
            .fullScreenCover(item: $activeWhoAmI, onDismiss: finishDailyGame) { puzzle in
                WhoAmIGameView(puzzle: puzzle).environmentObject(container)
            }
            .fullScreenCover(item: $activeJourneyman, onDismiss: finishDailyGame) { puzzle in
                JourneymanGameView(puzzle: puzzle).environmentObject(container)
            }
            // The arcade covers carry `onDismiss: evaluateMoment` where they previously carried
            // nothing: a Grid or Over/Under session is just as much a finished game as a daily,
            // and the moment layer's post-game trigger has to fire for all of them or the
            // thresholds in `MomentEngine` silently only count dailies.
            .fullScreenCover(isPresented: $showOverUnder, onDismiss: evaluateMoment) {
                OverUnderGameView().environmentObject(container)
            }
            .fullScreenCover(isPresented: $showDraftSpin, onDismiss: evaluateMoment) {
                DraftSpinView().environmentObject(container)
            }
            .fullScreenCover(isPresented: $showDailyDraft, onDismiss: evaluateMoment) {
                DraftSpinView(startInDailyDraft: true).environmentObject(container)
            }
            .fullScreenCover(isPresented: $showGrid, onDismiss: evaluateMoment) {
                GridGameView().environmentObject(container)
            }
            .fullScreenCover(isPresented: $showBlitz, onDismiss: evaluateMoment) {
                BlitzGameView().environmentObject(container)
            }
            .navigationDestination(isPresented: $showKeep4Hub) {
                BrowseView(pinnedFormat: .keep4).environmentObject(container)
            }
            .navigationDestination(isPresented: $showWhoAmIHub) {
                BrowseView(pinnedFormat: .whoami).environmentObject(container)
            }
            .navigationDestination(isPresented: $showJourneymanHub) {
                BrowseView(pinnedFormat: .journeyman).environmentObject(container)
            }
            .sheet(item: $shareTarget) { target in
                PuzzleShareSheet(puzzle: target, surface: "puzzle_home")
                    .environmentObject(container)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(trigger: paywallTrigger).environmentObject(container)
            }
            .task(id: container.sportFilter) { await loadDaily() }
            .task { await refreshPushPrimer() }
            // The two triggers that catch a day rollover while the process stays alive:
            // `.NSCalendarDayChanged` fires at local midnight (and on timezone/clock changes)
            // when the app is frontmost — the countdown card hits 00:00:00 and the fresh
            // daily appears live; scenePhase catches the far more common case of resuming
            // from background on a later day, which the notification (delivered only to a
            // running, scheduled runloop) can sleep straight through.
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .receive(on: RunLoop.main)) { _ in refreshDailiesIfNewDay() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshDailiesIfNewDay() }
            }
        }
    }

    /// Throw away the per-sport daily cache when the local calendar day has moved on from the
    /// one it was loaded for. No-op within the same day, so scenePhase churn (control center,
    /// notification shade) never causes spurious refetches.
    ///
    /// Deliberately does NOT kick off the reload itself: every page's own
    /// `.task(id:)` keys on `dailiesDay` (see `dailyCardStack`), so mounted pages re-fire the
    /// moment this changes and unmounted ones load when first swiped to. Calling `loadDaily()`
    /// here instead would reset the pager to the last-played sport under a reader mid-swipe,
    /// and re-run the DEBUG auto-open flags — a midnight rollover would launch a game by itself.
    private func refreshDailiesIfNewDay() {
        let today = PuzzleStore.localDayString()
        guard today != dailiesDay else { return }
        dailiesDay = today
        loadedSports.removeAll()
        keep4BySport.removeAll()
        whoAmIBySport.removeAll()
        journeymanBySport.removeAll()
    }

    /// Current streak, shown inline in the page body (not a nav-bar icon — that read as a
    /// broken logo on other tabs since each tab's toolbar item meant something different).
    private var streakRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(container.streak > 0 ? Color.warningFill : Color.textMuted)
            Text(HomeDailyLoop.streakLabel(streak: container.streak))
                .font(.label12)
                .foregroundStyle(Color.textPrimary)
        }
    }

    // MARK: - Streak reminders (activation)

    /// The only place the app asks for notification permission outside Profile's settings card.
    ///
    /// It shows up *after* the first completed game rather than at launch, because iOS gives one
    /// prompt per install and a cold ask (no streak yet, no reason given) spends it for nothing.
    /// Answering either way retires the card for good — the OS prompt can't be shown twice, so a
    /// second ask would be a dead button.
    ///
    /// No dedicated event: `app_opened` carries the authorization status on every launch, which
    /// splits installs three ways (`authorized` converted, `denied` refused at the OS prompt,
    /// still `not_determined` never engaged) without a second event to keep in sync.
    private var pushPrimerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color.warningFill)
                Text("DON'T LOSE YOUR STREAK")
                    .font(.heading)
                    .foregroundStyle(Color.textPrimary)
            }
            Text("One nudge at 8pm if today's puzzles are still open. Nothing else.")
                .font(.label12)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { Task { await enableReminders() } } label: {
                    Text("TURN ON REMINDERS")
                        .font(.custom(FontName.condBlack, size: 14))
                        .foregroundStyle(Color.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.accentFill)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(PrimePressStyle())

                Button { answerPrimer() } label: {
                    Text("Not now")
                        .font(.bodyStrong)
                        .foregroundStyle(Color.textMuted)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockCard()
    }

    // MARK: - Moments (post-onboarding prompts)

    /// The armed moment, but only in its quieter second-ask form — the first ask is a sheet
    /// presented from `ContentView`, and rendering both would be the same prompt twice on one
    /// screen. Never shown alongside `pushPrimerCard`; `MomentEngine` already refuses to arm
    /// anything while that card is live (see `MomentContext.pushPrimerPending`), and the `else if`
    /// at the call site is the belt to that's braces.
    private var inlineMoment: Moment? {
        moments.style == .inline ? moments.pending : nil
    }

    private func momentCard(_ moment: Moment) -> some View {
        MomentInlineCard(moment: moment, context: moments.context,
                         onTap: { Haptics.tap(); moments.escalate() },
                         onDismiss: { withAnimation(Motion.easeOut) { moments.dismiss() } })
            .onAppear { moments.markShown(container: container) }
    }

    /// Offered only once a streak actually exists (i.e. a game was completed) and only while the
    /// system prompt is still unspent — a `denied` install must never see it again.
    private func refreshPushPrimer() async {
        if DebugLaunch.forcePushPrimer { showPushPrimer = true; return }
        showPushPrimer = await PushPrimer.shouldOffer()
    }

    private func enableReminders() async {
        Haptics.tap()
        await PushNotificationManager.requestAuthorizationAndRegister()
        answerPrimer()
    }

    private func answerPrimer() {
        ActivationState().markOnce(.pushPrimerAnswered)
        withAnimation(Motion.easeOut) { showPushPrimer = false }
    }

    /// Entry point to the full archive (every daily puzzle, not just today's). Pro-gated —
    /// tapping while locked opens the paywall instead (see `HomeView.body`'s Button action).
    private var browseRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse all puzzles").font(.title).foregroundStyle(Color.textPrimary)
                Text("REPLAY THE FULL ARCHIVE").font(.label11).foregroundStyle(Color.textMuted)
            }
            Spacer()
            if !container.entitlements.canAccessArchive {
                Text("PRO")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.proText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.proBg)
                    .clipShape(Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    /// Home's daily cards are one of exactly two surfaces a brand-new player's first game can
    /// start from (onboarding's guided game is the other), so both record the same milestone —
    /// `ActivationMilestone` de-dupes, and a player who skipped the guided game still counts.
    private func launchDaily(format: String, id: String, sport: Sport) {
        launchedDaily = LaunchedDaily(format: format, puzzleID: id, sport: sport)
        ActivationMilestone.noteFirstGameStarted(container, format: format, sport: sport,
                                                 surface: "home_daily")
    }

    /// Reads the win back off progress once the game's cover closes — `hasCompletedToday` is
    /// true only for a puzzle that was actually finished, so quitting mid-round records a start
    /// with no completion (which is the drop-off worth seeing).
    private func finishDailyGame() {
        if let launched = launchedDaily, container.hasCompletedToday(puzzleID: launched.puzzleID) {
            ActivationMilestone.noteFirstGameCompleted(container, format: launched.format,
                                                       sport: launched.sport, surface: "home_daily")
        }
        launchedDaily = nil
        // A first completion is exactly when the streak becomes worth protecting, so re-evaluate
        // the reminder primer here rather than waiting for the next launch. The moment layer runs
        // *after* it, and only if it declined — `MomentEngine` reads the same `PushPrimer` answer.
        Task {
            await refreshPushPrimer()
            await moments.evaluate(container: container, trigger: .postGame)
        }
    }

    /// Post-game moment trigger for the covers that record nothing else. Runs from `onDismiss`,
    /// never from inside the game: a `.sheet` cannot present over a live `fullScreenCover`, and a
    /// moment armed under one would be marked shown for a sheet the player never saw.
    private func evaluateMoment() {
        Task { await moments.evaluate(container: container, trigger: .postGame) }
    }

    private func launch(_ format: GameFormat) {
        switch format.id {
        case "keep4": showKeep4Hub = true
        case "whoami": showWhoAmIHub = true
        case "journeyman": showJourneymanHub = true
        case "versus": selectedTab = 2
        case "overunder": showOverUnder = true
        // Free, like Over/Under and unlike the two packs: Blitz is an engagement surface
        // (BALLIQ_SPEC §9.3 sequences those first) and it serves boards the player can't choose,
        // which is a different product from the Pro archive's browse-and-replay.
        case "blitz": showBlitz = true
        case "draft": launchDraftSpin(daily: false)
        case "grid":
            if container.entitlements.canPlayGrid() { showGrid = true }
            else { paywallTrigger = .grid; showPaywall = true }
        default: break
        }
    }

    /// The $1.99 draft-spin pack (or Pro/admin) gate, mirroring `canPlayGrid()`'s enforcement
    /// exactly — `canPlayDraftSpin()` existed on `Entitlements` but was never called anywhere,
    /// which meant the pack unlocked nothing. Covers both entry points (the formats-grid tile
    /// and the daily-loop countdown card's Daily Draft row) so neither walks past the paywall.
    private func launchDraftSpin(daily: Bool) {
        guard container.entitlements.canPlayDraftSpin() else {
            paywallTrigger = .draftSpin
            showPaywall = true
            return
        }
        if daily { showDailyDraft = true } else { showDraftSpin = true }
    }

    /// Lands the pager on the last-played sport and makes sure that page's dailies are ready
    /// before any debug/screenshot auto-open runs. Every other sport's page lazy-loads itself
    /// via `dailyCardStack(for:)`'s own `.task` once the pager actually mounts it (a swipe, or
    /// whatever neighbor pages `DailyGamesPager`'s scroll view keeps warm on its own) —
    /// `loadDaily(for:)` is idempotent via `loadedSports`, so this never double-fetches the
    /// initial sport.
    private func loadDaily() async {
        let initial = container.sportFilter.sport ?? .nfl
        dailyPage = initial
        // Warm the arcade pool for the sport the player is most likely to spin next (their
        // last-played sport) while they're still looking at Home — Draft & Spin and
        // Over/Under then open with a hot cache instead of a first-fetch spinner.
        container.catalog.prefetchDraftSpinSample(for: initial)
        // Same idea for The Grid, which is the slowest format to open by a wide margin: its
        // board and its typeahead index are both fetched, not bundled, and both are only
        // started once the player has already tapped through the setup screen. Warming here
        // means the tap lands on a disk hit.
        //
        // Gated on `canPlayGrid()` rather than fired for everyone: the Grid is paid, so warming
        // it for a free player spends their bandwidth on a board the paywall will stop them
        // opening. This is the launch path — it runs for every session, on cellular.
        if container.entitlements.canPlayGrid() {
            container.puzzles.prefetchGrid(for: initial)
        }
        await loadDaily(for: initial)
        if DebugLaunch.autoOpenWhoAmI, activeWhoAmI == nil {
            activeWhoAmI = whoAmIBySport[initial]?.content
        } else if DebugLaunch.autoOpenJourneyman, activeJourneyman == nil {
            activeJourneyman = journeymanBySport[initial]?.content
        } else if DebugLaunch.autoOpenGame, activePuzzle == nil {
            activePuzzle = keep4BySport[initial]?.content
        } else if DebugLaunch.autoOpenBrowse {
            showBrowse = true
        } else if DebugLaunch.autoOpenOverUnder {
            showOverUnder = true
        } else if DebugLaunch.autoOpenDailyDraft {
            showDailyDraft = true
        } else if DebugLaunch.autoOpenDraftSpin {
            showDraftSpin = true
        } else if DebugLaunch.autoOpenGrid {
            showGrid = true
        } else if DebugLaunch.autoOpenBlitz {
            showBlitz = true
        }
    }

    /// Fetches one sport's daily pair exactly once per Home session — `RemotePuzzleRepository`
    /// disk-caches per (format, sport) underneath this, so a first-time fetch for a sport the
    /// player swipes to is the only real network hit; every page after that is instant.
    private func loadDaily(for sport: Sport) async {
        guard !loadedSports.contains(sport) else { return }
        loadedSports.insert(sport)
        let filter = SportFilter(rawValue: sport.rawValue) ?? .all
        // Independent reads — starting them together removes an avoidable round trip.
        async let keep4Task = container.puzzles.keep4Puzzle(for: filter, date: Date())
        async let whoAmITask = container.puzzles.whoAmIPuzzle(for: filter, date: Date())
        async let journeymanTask = container.puzzles.journeymanPuzzle(for: filter, date: Date())
        keep4BySport[sport] = await keep4Task
        whoAmIBySport[sport] = await whoAmITask
        journeymanBySport[sport] = await journeymanTask
        // The player is on Home, which draws no headshots — spend that idle network on the
        // photos this sport's dailies will need if they open one. Bounded and .utility, so it
        // yields to anything actually on screen; see PuzzleImageWarmer.
        PuzzleImageWarmer.warmDailies(
            keep4: [keep4BySport[sport]?.content].compactMap { $0 },
            journeyman: [journeymanBySport[sport]?.content].compactMap { $0 })
    }

    /// One pager page: that sport's K4C4 + Who Am I? daily cards, stacked exactly like the
    /// former single-sport layout. Its own `.task(id:)` is the lazy-load trigger for every
    /// sport besides the initial one (see `loadDaily()`'s doc comment).
    @ViewBuilder
    private func dailyCardStack(for sport: Sport) -> some View {
        VStack(spacing: 14) {
            if let pick = keep4BySport[sport] {
                let puzzle = pick.content
                DailyGameCard(formatName: "K4C4",
                              symbol: "rectangle.stack.fill",
                              sport: puzzle.sport,
                              title: puzzle.theme,
                              subtitle: "\(puzzle.players.count) \(puzzle.puzzleGrain().countNoun)",
                              scoring: puzzle.scoringKind(),
                              grain: puzzle.puzzleGrain(),
                              completed: container.hasCompletedToday(puzzleID: puzzle.id),
                              favoriteTeamMatch: container.favoriteTeams.team(for: puzzle.sport)
                                  .map(puzzle.features(teamAbbr:)) ?? false,
                              ranked: true,
                              dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                    // The daily card IS the puzzle — it opens directly (explicit feedback: no
                    // intermediate setup screen when the puzzle is already loaded and shown on
                    // the card). The formats grid below still routes through setup, where
                    // picking a sport is the point.
                    launchDaily(format: "keep4", id: puzzle.id, sport: puzzle.sport)
                    activePuzzle = puzzle
                }
                secondaryAction: { shareTarget = SharablePuzzle(keep4: puzzle) }
            } else {
                dailyCardPlaceholder(loaded: loadedSports.contains(sport))
            }
            if let pick = whoAmIBySport[sport] {
                let puzzle = pick.content
                DailyGameCard(formatName: "Who am I?",
                              symbol: "questionmark.circle.fill",
                              sport: puzzle.sport,
                              title: String(localized: "Guess today's mystery player"),
                              subtitle: String(localized: "\(puzzle.clues.count) clues"),
                              difficulty: puzzle.difficulty,
                              completed: container.hasCompletedToday(puzzleID: puzzle.id),
                              typeColor: .voltFill, onTypeColor: .onVolt,
                              ranked: true,
                              dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                    launchDaily(format: "whoami", id: puzzle.id, sport: puzzle.sport)
                    activeWhoAmI = puzzle
                }
                secondaryAction: { shareTarget = SharablePuzzle(whoAmI: puzzle) }
            } else {
                dailyCardPlaceholder(loaded: loadedSports.contains(sport))
            }
            if let pick = journeymanBySport[sport] {
                let puzzle = pick.content
                // No `secondaryAction`: the pre-game share sheet renders a puzzle preview, and
                // for this format the preview IS the board — there's nothing to show that
                // wouldn't hand the reader the first club for free.
                DailyGameCard(formatName: "Journeyman",
                              symbol: "arrow.triangle.branch",
                              sport: puzzle.sport,
                              title: String(localized: "Name the player from their clubs"),
                              subtitle: String(localized: "\(puzzle.stints.count) clubs"),
                              difficulty: puzzle.difficulty,
                              completed: container.hasCompletedToday(puzzleID: puzzle.id),
                              typeColor: .goldFill, onTypeColor: .onGold,
                              ranked: true,
                              dateBadge: pick.isCanonicalToday ? DailyGameCard.todayDateBadge : nil) {
                    launchDaily(format: "journeyman", id: puzzle.id, sport: puzzle.sport)
                    activeJourneyman = puzzle
                }
            } else {
                dailyCardPlaceholder(loaded: loadedSports.contains(sport))
            }
        }
        // Keyed on the day as well as the sport: `refreshDailiesIfNewDay` only clears state,
        // and a bare `id: sport` would never re-fire for an already-mounted page — the cards
        // would sit on an empty map showing a spinner that nothing ever resolves.
        .task(id: "\(sport.rawValue)-\(dailiesDay)") { await loadDaily(for: sport) }
    }

    /// Fills a daily card's spot while its sport's page is still loading, so the pager doesn't
    /// visibly collapse/reflow mid-swipe. `loaded` true with no puzzle is a genuine empty
    /// result (no spinner — there's nothing coming), matching the pre-pager single-sport
    /// behavior of simply omitting the card.
    @ViewBuilder
    private func dailyCardPlaceholder(loaded: Bool) -> some View {
        if !loaded {
            HStack {
                Spacer()
                ProgressView().tint(.accentFill)
                Spacer()
            }
            .frame(height: 96)
            .cardSurface()
        }
    }

    @ViewBuilder
    // LocalizedStringKey so the three literal section titles extract into
    // Localizable.xcstrings — same pattern as EmptyStateView/GameSetupScreen.
    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Broadcast lower-third chip instead of bare ink text (2026-07-17 "too much
            // white" pass) — shared with the format hubs via `LowerThirdHeader`.
            LowerThirdHeader(title: title)
            content()
        }
    }
}

/// The daily a `fullScreenCover(item:)` is currently showing, kept beside the item because the
/// cover's `onDismiss` closure runs after the item has already been cleared.
private struct LaunchedDaily {
    let format: String
    let puzzleID: String
    let sport: Sport
}

#Preview {
    HomeView(selectedTab: .constant(0)).environmentObject(RepositoryContainer.make())
}
