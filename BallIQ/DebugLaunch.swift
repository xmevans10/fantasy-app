import Foundation

/// Launch-argument hooks used only for automated UI verification (screenshots).
/// Compiled out of release builds.
enum DebugLaunch {
    #if DEBUG
    private static func has(_ arg: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(arg)
    }
    static var autoOpenGame: Bool { has("-screenshotGame") || has("-screenshotResult") }
    static var autoOpenWhoAmI: Bool { has("-screenshotWhoAmI") || has("-screenshotWhoAmIResult") }
    static var autoOpenJourneyman: Bool {
        has("-screenshotJourneyman") || has("-screenshotJourneymanResult")
    }
    /// `-autoSubmit` alone works with `-openURL` (deep-linked game → result) without also
    /// auto-opening the daily the way `-screenshotResult` does.
    static var autoSubmitResult: Bool {
        has("-screenshotResult") || has("-screenshotWhoAmIResult")
            || has("-screenshotJourneymanResult") || has("-autoSubmit")
    }
    static var autoOpenCreateKeep4: Bool { has("-screenshotCreate") }
    static var autoOpenStats: Bool { has("-screenshotStats") }
    static var autoOpenProfile: Bool { has("-screenshotProfile") }
    static var autoOpenLeagues: Bool { has("-screenshotLeagues") }
    /// Opens Leagues on the SEASON scope and bypasses the sign-in gate so the 8-week rating-season
    /// chrome (hero + season-end countdown + board) can be captured without a real account:
    /// `-screenshotSeason`. The board itself is whatever the live season currently holds.
    static var autoOpenSeason: Bool { has("-screenshotSeason") }
    static var autoOpenVersus: Bool { has("-screenshotVersus") || has("-screenshotLadder") }
    /// Pushes the bot ladder from the Versus tab. Separate from `-screenshotVersus` because the
    /// ladder is a pushed screen, not the tab root, and it renders signed-out (content is
    /// world-readable; only playing a rung needs an account).
    static var autoOpenLadder: Bool { has("-screenshotLadder") }
    /// Starts the first unlocked rung's board with no taps (the briefing sheet's START button is
    /// a real tap simctl can't drive): `-screenshotLadderDuel`. Needed because the live-reaction
    /// speech bubble (`DuelStatusBar`) only fires once real time has passed on a hosted view — a
    /// static render can't produce it, so this is the only way to screenshot it at all.
    static var autoStartLadderDuel: Bool { has("-screenshotLadderDuel") }
    static var autoOpenCommunity: Bool { has("-screenshotCommunity") }
    static var autoOpenBrowse: Bool { has("-screenshotBrowse") }
    static var autoOpenModeration: Bool { has("-screenshotModeration") }
    static var autoOpenPaywall: Bool { has("-screenshotPaywall") }
    /// Grants Pro for the session so the Pro-gated surfaces can be driven/screenshot without a
    /// StoreKit purchase or a signed-in entitled account: `-screenshotPro`. Without it, a plain
    /// `simctl` session is free-tier, and every soccer/MLB/tennis flag silently lands on NFL —
    /// `GameSetupScreen.correctLockedDefault` snaps the locked sport back, which for Draft & Spin
    /// looks exactly like a content bug (soccer's 8 lineup slots against an NFL pool → an instant
    /// empty-lineup result). Reads through `Entitlements.isPro`, so it also unlocks Hard mode, the
    /// archive, The Grid and Over/Under's no-wait refill (not unlimited lives — a Pro run still
    /// ends on the third miss).
    static var forcePro: Bool { has("-screenshotPro") }
    static var autoOpenOverUnder: Bool {
        has("-screenshotOverUnder") || has("-screenshotOverUnderResult") || has("-screenshotOverUnderEmpty")
    }
    /// Drains the Over/Under lives bank at open so the out-of-lives *gate* (the wait + upsell that
    /// stands in front of the setup screen) can be captured: `-screenshotOverUnderEmpty`. The bank
    /// lives in UserDefaults and a real drain takes three deliberate misses, so there is no other
    /// way to reach this screen from `simctl` — and writing the defaults from outside doesn't
    /// stick, since a running app's `cfprefsd` rewrites the plist from its own in-memory copy.
    static var forceEmptyOverUnderLives: Bool { has("-screenshotOverUnderEmpty") }
    /// Forces an immediate out-of-lives finish once the session loads (simctl can't play a real
    /// round-by-round session): `-screenshotOverUnderResult`.
    static var autoSubmitOverUnder: Bool { has("-screenshotOverUnderResult") }
    static var autoOpenDraftSpin: Bool {
        has("-screenshotDraftSpin") || has("-screenshotDraftSpinResult")
            || has("-screenshotDraftSpinSetup") || has("-screenshotDraftSpinReveal")
    }
    /// Auto-picks the first candidate in every slot (simctl can't tap through the draft board).
    static var autoSubmitDraftSpin: Bool { has("-screenshotDraftSpinResult") }
    /// Stops on the pre-game setup screen instead of skipping into the board
    /// (the other DraftSpin flags exist to capture the board/result, so they skip setup).
    static var holdDraftSpinSetup: Bool { has("-screenshotDraftSpinSetup") || has("-screenshotDailyDraftSetup") }
    /// Opens Draft & Spin already in Daily Draft mode (Home's daily-loop row path) and holds
    /// on setup — the MODE toggle needs a tap simctl can't do, and the Daily Draft setup
    /// state (forced sport-of-the-day, gate exemption) is exactly what needs capturing.
    static var autoOpenDailyDraft: Bool { has("-screenshotDailyDraftSetup") }
    /// Freezes the slot-machine reveal in its settled ("LOCKED IN") state instead of
    /// advancing to the board, so the casino styling itself can be screenshot.
    static var holdDraftSpinReveal: Bool { has("-screenshotDraftSpinReveal") }
    static var autoOpenGrid: Bool {
        has("-screenshotGrid") || has("-screenshotGridResult") || has("-screenshotGridSetup")
    }
    /// Opens The Grid but holds on its setup screen instead of loading a board — same reason
    /// `holdDraftSpinSetup` exists: the setup screen is itself what needs capturing (the
    /// sport picker and the "new random grid" button), and reaching it otherwise needs a tap
    /// simctl can't do.
    static var holdGridSetup: Bool { has("-screenshotGridSetup") }
    /// Auto-answers every cell with its first valid answer (simctl can't type into the guess field).
    static var autoSubmitGrid: Bool { has("-screenshotGridResult") }
    /// Browse: auto-open the pre-play share sheet for the first archive puzzle. Consumed
    /// inside BrowseView, so it only fires combined with the flag that gets there:
    /// `-screenshotBrowse -screenshotShare`. Standalone it's a silent no-op (verified 2026-07-13).
    /// Puzzle Blitz. `-screenshotBlitzSetup` holds on the setup screen (the only blitz surface a
    /// single screenshot can reach reliably); `-screenshotBlitz` starts a run and lands on the
    /// first board, whichever format it happens to deal.
    static var autoOpenBlitz: Bool { has("-screenshotBlitz") || has("-screenshotBlitzSetup") }
    static var holdBlitzSetup: Bool { has("-screenshotBlitzSetup") }

    static var autoOpenShare: Bool { has("-screenshotShare") }
    /// Keep4 game: auto-open the scoring-formula sheet (simctl can't tap the chip). Same
    /// combination rule as `autoOpenShare`: needs `-screenshotGame -screenshotScoringInfo`.
    static var autoOpenScoringInfo: Bool { has("-screenshotScoringInfo") }
    /// Auto-present the "How it works" explainer sheets (simctl can't tap the info button).
    /// Combination flags like `autoOpenScoringInfo`: `-screenshotLeagues -screenshotLeaguesInfo`,
    /// `-screenshotVersus -screenshotVersusInfo`, `-screenshotDraftSpinSetup -screenshotDailyDraftInfo`.
    static var autoOpenLeaguesInfo: Bool { has("-screenshotLeaguesInfo") }
    static var autoOpenVersusInfo: Bool { has("-screenshotVersusInfo") }
    static var autoOpenDailyDraftInfo: Bool { has("-screenshotDailyDraftInfo") }
    /// Auto-present the nation-grouped league picker sheet (simctl can neither scroll the setup
    /// screen down to the LEAGUE row nor tap it). Combination flag like the ones above:
    /// `-screenshotPro -screenshotDraftSpinSetup -draftSpinSport soccer -screenshotLeaguePicker`.
    static var autoOpenLeaguePicker: Bool { has("-screenshotLeaguePicker") }
    /// Force the Leagues promotion/relegation recap banner for capture (real state needs a
    /// prior rollover): `-forcePriorZone promoted` or `-forcePriorZone relegated`.
    static var forcePriorZone: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-forcePriorZone"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Force the Leagues "your league starts Monday" empty-state countdown even when the
    /// account has a membership: `-forceLeagueCountdown`.
    static var forceLeagueCountdown: Bool { has("-forceLeagueCountdown") }
    /// Prefill the Browse search field (simctl can't type): `-searchQuery lamb`.
    static var searchQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-searchQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Preselect Browse's sport dropdown (simctl can't tap it): `-browseSport soccer`.
    static var browseSport: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-browseSport"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Auto-apply a Create-flow theme template by key (simctl can't tap chips):
    /// `-screenshotCreateTheme nba-career-fantasy`.
    static var createTemplateKey: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotCreateTheme"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Override Draft & Spin's date-seeded sport-of-the-day (simctl can't wait for a lucky
    /// date to test a specific sport's season shape/outcome titles): `-draftSpinSport soccer`.
    static var draftSpinSport: Sport? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-draftSpinSport"), i + 1 < args.count else { return nil }
        return Sport(rawValue: args[i + 1])
    }
    /// Preselect the board's position tab (simctl can't tap a tab, and defensive position
    /// sections sit below the fold on the All tab): `-draftSpinPosition CB`.
    static var draftSpinPosition: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-draftSpinPosition"), i + 1 < args.count else { return nil }
        return args[i + 1].uppercased()
    }
    /// Auto-expand the first player of the preselected position (simctl can't tap a row) so
    /// the full `PositionStatGrid` line can be captured: `-draftSpinPosition DE -draftSpinExpand`.
    static var autoExpandDraftSpin: Bool { has("-draftSpinExpand") }
    /// Force the NFL ROSTER setting to Both sides (simctl can't tap the segmented control):
    /// `-draftSpinBothSides`. Defaults the draft to the 9-slot offense+DL/LB/DB formation.
    static var draftSpinBothSides: Bool { has("-draftSpinBothSides") }
    /// Seed Draft & Spin's Nation → League → Club filter so a division-scoped draft can be
    /// driven without tapping through the picker: `-draftSpinCompetition ger.2 -draftSpinNation Germany`.
    /// This is how "does a 2. Bundesliga draft actually return 2. Bundesliga players?" gets
    /// verified on device rather than asserted.
    static var draftSpinCompetition: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-draftSpinCompetition"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static var draftSpinNation: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-draftSpinNation"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Open the Nation → League → Club picker already drilled into one nation, so the DIVISION
    /// level is reachable without a tap (simctl can't tap a list row — the same reason
    /// `-screenshotLeaguePicker` exists at all): `-screenshotLeagueNation Germany`.
    static var screenshotLeagueNation: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotLeagueNation"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Jump the first-run flow to a given step so each one can be captured without tapping
    /// through the previous ones (simctl can't tap): `-screenshotOnboardingStep how_to_play`.
    /// Values are `OnboardingStep` raw values. Only has an effect on a genuinely fresh install —
    /// `hasOnboarded` still gates whether onboarding renders at all, and `simctl uninstall`
    /// alone does NOT clear it (cfprefsd caches the domain; `defaults delete` first).
    static var onboardingStep: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotOnboardingStep"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Force Home's streak-reminder primer card visible regardless of streak or notification
    /// status: `-screenshotPushPrimer`. Real state needs a completed game *and* an untouched
    /// system prompt, which can't both be arranged from a launch argument.
    static var forcePushPrimer: Bool { has("-screenshotPushPrimer") }
    /// Force one post-onboarding moment on screen, past every gate:
    /// `-screenshotMoment claim_username` / `favorite_team` / `add_friend` (see
    /// `Moment.analyticsID`). Real state needs a specific games-played count, streak, sign-in
    /// state and an unexpired 48h cooldown all at once — none of which a launch argument can
    /// arrange, and all of which AGENTS.md §5 still expects screenshots of.
    ///
    /// `favorite_team` resolves against `-screenshotMomentSport` (default NBA) so the outlier
    /// case — soccer, whose `TeamPicker` carries 201 clubs — is reachable.
    static var forcedMoment: Moment? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotMoment"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "claim_username": return .claimUsername
        case "favorite_team":  return .favoriteTeam(forcedMomentSport)
        case "add_friend":     return .addFriend
        default:               return nil
        }
    }

    private static var forcedMomentSport: Sport {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotMomentSport"), i + 1 < args.count,
              let sport = Sport(rawValue: args[i + 1]) else { return .nba }
        return sport
    }

    /// Feed a deep link straight to `ContentView.handle` (bypasses SpringBoard's
    /// "Open in …?" confirm, which automated runs can't tap): `-openURL balliq://play/<id>`.
    static var openURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openURL"), i + 1 < args.count else { return nil }
        return URL(string: args[i + 1])
    }
    /// Skip StoreKit's launch-time catalog fetch + entitlement refresh (see
    /// `StoreService.init`). On a simulator with no Apple ID, `Product.products(for:)` raises
    /// the system "Sign in to Apple Account" sheet, which overlays every simctl screenshot
    /// run: `-skipStoreKit`.
    static var skipStoreKit: Bool { has("-skipStoreKit") }
    /// Open Who Am I? with the first N clues already revealed, without solving the board:
    /// `-screenshotWhoAmIClues 3`. `-screenshotWhoAmI` alone shows one clue over a screen of
    /// empty cream, which is what made the live App Store shot promise "SIX CLUES" over an
    /// image containing none. Distinct from `autoSubmitResult`'s `autoSolveForScreenshot`,
    /// which reveals three and then *finishes* the board — that lands on the result, not the
    /// game. 0 = leave it alone.
    static var whoAmIRevealedClues: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotWhoAmIClues"), i + 1 < args.count,
              let n = Int(args[i + 1]) else { return 0 }
        return n
    }
    #else
    static let autoOpenGame = false
    static let autoOpenWhoAmI = false
    static let whoAmIRevealedClues = 0
    static let autoOpenJourneyman = false
    static let autoSubmitResult = false
    static let autoOpenCreateKeep4 = false
    static let autoOpenStats = false
    static let autoOpenProfile = false
    static let autoOpenLeagues = false
    static let autoOpenSeason = false
    static let autoOpenVersus = false
    static let autoOpenLadder = false
    static let autoStartLadderDuel = false
    static let autoOpenCommunity = false
    static let autoOpenBrowse = false
    static let autoOpenModeration = false
    static let autoOpenPaywall = false
    static let forcePro = false
    static let autoOpenOverUnder = false
    static let forceEmptyOverUnderLives = false
    static let autoSubmitOverUnder = false
    static let autoOpenDraftSpin = false
    static let autoSubmitDraftSpin = false
    static let holdDraftSpinSetup = false
    static let autoOpenDailyDraft = false
    static let holdDraftSpinReveal = false
    static let autoOpenGrid = false
    static let autoSubmitGrid = false
    static let holdGridSetup = false
    static let autoOpenBlitz = false
    static let holdBlitzSetup = false
    static let autoOpenShare = false
    static let autoOpenScoringInfo = false
    static let autoOpenLeaguesInfo = false
    static let autoOpenVersusInfo = false
    static let autoOpenDailyDraftInfo = false
    static let autoOpenLeaguePicker = false
    static let screenshotLeagueNation: String? = nil
    static let draftSpinCompetition: String? = nil
    static let draftSpinNation: String? = nil
    static let forcePriorZone: String? = nil
    static let forceLeagueCountdown = false
    static let searchQuery: String? = nil
    static let browseSport: String? = nil
    static let createTemplateKey: String? = nil
    static let onboardingStep: String? = nil
    static let forcePushPrimer = false
    static let forcedMoment: Moment? = nil
    static let openURL: URL? = nil
    static let draftSpinSport: Sport? = nil
    static let draftSpinPosition: String? = nil
    static let autoExpandDraftSpin = false
    static let draftSpinBothSides = false
    static let skipStoreKit = false
    #endif
}
