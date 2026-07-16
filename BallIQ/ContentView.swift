import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var container: RepositoryContainer
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
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(4)
        }
        .onOpenURL { url in Task { await handle(url) } }
        .onChange(of: scenePhase) { _, phase in
            // Foreground refresh — the only "push" the Versus badge gets until APNs ships.
            if phase == .active { Task { await container.refreshVersusBadge() } }
        }
        .onAppear {
            if let url = DebugLaunch.openURL { Task { await handle(url) } }
            if DebugLaunch.autoOpenCreateKeep4 { debugCreate = true }
            if DebugLaunch.autoOpenStats { selectedTab = 4 }   // Profile tab; it auto-pushes Stats
            if DebugLaunch.autoOpenProfile { selectedTab = 4 }
            if DebugLaunch.autoOpenModeration { selectedTab = 4 }   // ditto for the review queue
            if DebugLaunch.autoOpenLeagues { selectedTab = 1 }
            if DebugLaunch.autoOpenVersus { selectedTab = 2 }
            if DebugLaunch.autoOpenCommunity { selectedTab = 3 }
            if DebugLaunch.autoOpenPaywall { debugPaywall = true }
        }
        .sheet(isPresented: $debugCreate) {
            NavigationStack { CreateKeep4View().environmentObject(container) }
        }
        .sheet(isPresented: $debugPaywall) {
            PaywallView().environmentObject(container)
        }
        .fullScreenCover(item: $linkKeep4) { link in
            Keep4GameView(puzzle: link.puzzle, ranked: false, communityID: link.communityID,
                          authorName: link.author)
                .environmentObject(container)
        }
        .fullScreenCover(item: $linkWhoAmI) { link in
            WhoAmIGameView(puzzle: link.puzzle, ranked: false, communityID: link.communityID)
                .environmentObject(container)
        }
    }

    /// Resolve `balliq://play/<id>` — community puzzles first, then the daily/archive
    /// pools (M13 pre-play sharing shares dailies too; the local fallback works offline).
    private func handle(_ url: URL) async {
        guard url.scheme == "balliq", url.host == "play",
              let id = url.pathComponents.last, !id.isEmpty else { return }
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
}

/// A deep-linked puzzle plus its presentation context, kept together so the fullScreenCover
/// closure never reads sibling state (see the stale-snapshot note on `linkKeep4`).
private struct LinkedPlay<P: Identifiable>: Identifiable where P.ID == String {
    let puzzle: P
    var communityID: String? = nil
    var author: String? = nil
    var id: String { puzzle.id }
}

/// Decides between splash, onboarding, and the main app.
struct RootView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showSplash = true

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
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return ContentView()
        .environmentObject(container)
        .environmentObject(container.auth)
}
