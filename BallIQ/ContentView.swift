import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @EnvironmentObject private var moments: MomentPresenter
    @Environment(\.scenePhase) private var scenePhase

    // Deep-link / share-link play (balliq://play/<id>). Requires the URL scheme to be
    // registered in Info.plist; the in-app feed works regardless.
    //
    // The puzzle, its community id, and its author travel in ONE presentation item: when they
    // were sibling @State vars, the fullScreenCover content closure evaluated with a stale
    // snapshot where the extras were still nil — every deep-linked community puzzle presented
    // with communityID nil (play never logged, report action hidden, author uncredited).
    @State private var linkKeep4: LinkedPlay<Keep4Puzzle>?
    @State private var linkWhoAmI: LinkedPlay<WhoAmIPuzzle>?
    /// An accepted `balliq://challenge` — the same-board head-to-head loop. Separate from
    /// `linkKeep4`/`linkWhoAmI` because a challenge names a *board* (sport + day), not a puzzle
    /// id, and resolves inside the game view rather than here.
    @State private var linkChallenge: ChallengeLink?
    /// A Grid challenge opened by someone without Pro — see `accept(_:)`.
    @State private var challengePaywall = false
    @State private var debugCreate = false
    @State private var debugPaywall = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            LeaguesView(selectedTab: $selectedTab)
                .tabItem { Label("Leagues", systemImage: "trophy.fill") }
                .tag(1)

            VersusView(selectedTab: $selectedTab)
                .tabItem { Label("Versus", systemImage: "bolt.fill") }
                .tag(2)
                // Explicit stopgap while APNs pushes for versus_challenge are stubbed — badge
                // absent when signed out or zero (`openVersusChallenges` resets to 0 in both cases).
                .badge(container.isSignedIn ? container.openVersusChallenges : 0)

            CommunityView()
                .tabItem { Label("Community", systemImage: "square.stack.3d.up.fill") }
                .tag(3)

            // Stats lives inside Profile — a 6th tab would push Profile into the system
            // "More" screen on iPhone (max 5 visible tabs).
            ProfileView(selectedTab: $selectedTab)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(4)
        }
        .onOpenURL { url in Task { await handle(url) } }
        .onChange(of: scenePhase) { _, phase in
            // Foreground refresh — the only "push" the Versus badge gets until APNs ships.
            if phase == .active { Task { await container.refreshVersusBadge() } }
            // A catalog that failed at launch used to stay failed for the whole process
            // lifetime unless the user found the paywall's "Try again". Coming back to the app
            // is the cheapest moment to retry — connectivity has usually changed — and it means
            // a reviewer who backgrounds the app once gets a fresh attempt without knowing to
            // ask for one.
            if phase == .active, container.productLoadState == .failed {
                Task { await container.reloadProducts() }
            }
            // The "came back" half of the moment layer (see `Moment`). Safe here and only here:
            // a `.sheet` cannot present over a live `fullScreenCover`, so arming one while a
            // game is on screen would silently burn it. Foregrounding means nothing is.
            if phase == .active {
                Task { await moments.evaluate(container: container, trigger: .foreground) }
            }
        }
        .onAppear {
            if let url = DebugLaunch.openURL { Task { await handle(url) } }
            if DebugLaunch.autoOpenCreateKeep4 { debugCreate = true }
            if DebugLaunch.autoOpenStats { selectedTab = 4 }   // Profile tab; it auto-pushes Stats
            if DebugLaunch.autoOpenProfile { selectedTab = 4 }
            if DebugLaunch.autoOpenModeration { selectedTab = 4 }   // ditto for the review queue
            if DebugLaunch.autoOpenLeagues || DebugLaunch.autoOpenSeason { selectedTab = 1 }
            if DebugLaunch.autoOpenVersus { selectedTab = 2 }
            if DebugLaunch.autoOpenCommunity { selectedTab = 3 }
            if DebugLaunch.autoOpenPaywall { debugPaywall = true }
        }
        // `onChange(of: scenePhase)` doesn't fire for the launch that arrives already-active, so
        // the first session needs its own trigger. `evaluate` is idempotent (it returns early
        // once something is pending or already shown this session), so the two can't double-arm.
        .task { await moments.evaluate(container: container, trigger: .foreground) }
        // The single presentation site for every moment, at the root rather than per screen, so
        // two can never race onto the screen together.
        .sheet(item: Binding(get: { moments.style == .sheet ? moments.pending : nil },
                             set: { if $0 == nil { moments.dismiss() } })) { moment in
            MomentSheet(moment: moment, context: moments.context)
                .environmentObject(container)
                .environmentObject(moments)
        }
        .sheet(isPresented: $debugCreate) {
            NavigationStack { CreateKeep4View().environmentObject(container) }
        }
        .sheet(isPresented: $debugPaywall) {
            PaywallView().environmentObject(container)
        }
        .fullScreenCover(item: $linkKeep4) { link in
            Keep4GameView(puzzle: link.puzzle, ranked: false, communityID: link.communityID,
                          authorName: link.author, challenge: link.challenge)
                .environmentObject(container)
        }
        .fullScreenCover(item: $linkChallenge) { challenge in
            GridGameView(challenge: challenge).environmentObject(container)
        }
        .sheet(isPresented: $challengePaywall) {
            PaywallView(trigger: .grid).environmentObject(container)
        }
        .fullScreenCover(item: $linkWhoAmI) { link in
            WhoAmIGameView(puzzle: link.puzzle, ranked: false, communityID: link.communityID,
                          challenge: link.challenge)
                .environmentObject(container)
        }
    }

    /// Resolve an inbound link. Two shapes exist:
    ///   - `balliq://challenge?…` — the head-to-head loop (`ChallengeLink`), which names a
    ///     *board* (sport + calendar day) rather than a puzzle id.
    ///   - `balliq://play/<id>` — M13 pre-play sharing: community puzzles first, then the
    ///     daily/archive pools (the local fallback works offline).
    private func handle(_ url: URL) async {
        if let challenge = ChallengeLink.parse(url) {
            await accept(challenge)
            return
        }
        guard url.scheme == "balliq", url.host == "play",
              let id = url.pathComponents.last, !id.isEmpty else { return }
        // Every inbound share link counts toward the loop's click-through, not just challenges.
        container.track(.shareLinkOpened, ["kind": "play", "puzzle_id": id])
        container.track(.communityPuzzlePlayed, ["source": "link", "puzzle_id": id])
        if let community = container.community {
            switch await community.load(id: id) {
            case .keep4(let p, let author):
                linkKeep4 = LinkedPlay(puzzle: p, communityID: id, author: author); return
            case .whoAmI(let p):
                linkWhoAmI = LinkedPlay(puzzle: p, communityID: id); return
            case .none: break
            }
        }
        // Not a community id: nil communityID so the game view doesn't log a community play.
        if let p = await container.puzzles.allKeep4(for: .all).first(where: { $0.id == id }) {
            linkKeep4 = LinkedPlay(puzzle: p)
        } else if let p = await container.puzzles.allWhoAmI(for: .all).first(where: { $0.id == id }) {
            linkWhoAmI = LinkedPlay(puzzle: p)
        }
    }

    /// Open the challenged board.
    ///
    /// The Grid resolves its own board inside `GridGameView` (it already owns a load path and an
    /// honest "that board's gone" state). Keep 4 and Who Am I? can't — both take a concrete
    /// puzzle — so they're resolved here, and the challenge is attached **only** on an exact
    /// match: `isCanonicalToday` false means the pool had no row for that day and `pick` fell
    /// back to a modulo choice, which would be a different puzzle wearing the right date.
    private func accept(_ challenge: ChallengeLink) async {
        container.track(.shareLinkOpened, [
            "kind": "challenge",
            "format": challenge.format.rawValue,
            "sport": challenge.sport.rawValue,
        ])
        switch challenge.format {
        case .grid:
            // The Grid is Pro-gated, and that gate lives on Home's launcher
            // (`HomeView.launch`) — presenting `GridGameView` straight from a deep link would
            // walk right past it and make a paid format free to anyone holding a link. Reuse
            // the existing check and the existing `.grid` trigger rather than widening access:
            // deciding that challenge links unlock Pro content is a pricing call, not a
            // routing one. The funnel this produces is a good one —
            // `share_link_opened → paywall_viewed(trigger: grid)` says exactly how much
            // demand the loop creates for the thing it can't give away.
            guard container.entitlements.canPlayGrid() else {
                challengePaywall = true
                return
            }
            linkChallenge = challenge
        case .keep4:
            guard let day = challenge.date else { return }
            let filter = SportFilter(rawValue: challenge.sport.rawValue) ?? .all
            guard let resolved = await container.puzzles.keep4Puzzle(for: filter, date: day)
            else { return }
            let exact = resolved.isCanonicalToday
            container.track(.challengeStarted, ["format": challenge.format.rawValue,
                                                "sport": challenge.sport.rawValue,
                                                "board": exact ? "exact" : "fallback"])
            linkKeep4 = LinkedPlay(puzzle: resolved.content, challenge: exact ? challenge : nil)
        case .whoami:
            guard let day = challenge.date else { return }
            let filter = SportFilter(rawValue: challenge.sport.rawValue) ?? .all
            guard let resolved = await container.puzzles.whoAmIPuzzle(for: filter, date: day)
            else { return }
            let exact = resolved.isCanonicalToday
            container.track(.challengeStarted, ["format": challenge.format.rawValue,
                                                "sport": challenge.sport.rawValue,
                                                "board": exact ? "exact" : "fallback"])
            linkWhoAmI = LinkedPlay(puzzle: resolved.content, challenge: exact ? challenge : nil)
        }
    }
}

/// A deep-linked puzzle plus its presentation context, kept together so the fullScreenCover
/// closure never reads sibling state (see the stale-snapshot note on `linkKeep4`).
private struct LinkedPlay<P: Identifiable>: Identifiable where P.ID == String {
    let puzzle: P
    var communityID: String? = nil
    var author: String? = nil
    /// Set only when the resolved board is *exactly* the one challenged — a fallback board
    /// carries nil, so the result screen can never compare two scores set on two puzzles.
    var challenge: ChallengeLink? = nil
    var id: String { puzzle.id }
}

/// Decides between splash, onboarding, and the main app.
struct RootView: View {
    @EnvironmentObject private var container: RepositoryContainer
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showSplash = true
    /// `.task` on a `Group` is applied to *each* child, and during the splash→app crossfade both
    /// children are briefly in the hierarchy — which logged `app_opened` twice per launch, and a
    /// double-counted launch is a halved activation rate. Verified against production `events`
    /// rows before and after (2026-07-27).
    @State private var recordedOpen = false

    var body: some View {
        Group {
            if showSplash {
                SplashView { withAnimation(Motion.easeOut) { showSplash = false } }
                    .transition(.opacity)
            } else if hasOnboarded {
                ContentView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .task { await openApp() }
    }

    /// Top of the activation funnel, and the one launch-time push obligation.
    ///
    /// `app_opened` fires here rather than in `ContentView` because it must count the launches
    /// that *never* reach the tab bar — a user who bounces on the onboarding screen is exactly
    /// the cohort the funnel is trying to measure. It carries `day_index`, which is how
    /// "next-day return" is read (see docs/ANALYTICS.md); a separate `next_day_return` event
    /// would be the same fact stored twice.
    private func openApp() async {
        guard !recordedOpen else { return }
        recordedOpen = true
        let open = ActivationState().recordOpen()
        // `push` on every launch is what makes the Home primer measurable without a second
        // event: an install that reads `not_determined` on day 0 and `authorized` later
        // converted, `denied` refused at the OS prompt, and still-`not_determined` never
        // engaged the card at all.
        let push = await PushNotificationManager.currentAuthorizationStatus()
        container.track(.appOpened, open.properties.merging([
            "signed_in": "\(container.isSignedIn)",
            "push": push.analyticsValue,
        ]) { current, _ in current })
        // Tokens are not stable and were previously only requested from Profile's settings card
        // — see `PushNotificationManager.registerIfAuthorized()`.
        await PushNotificationManager.registerIfAuthorized()
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return ContentView()
        .environmentObject(container)
        .environmentObject(container.auth)
}
