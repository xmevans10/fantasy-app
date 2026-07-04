import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var container: RepositoryContainer

    // Deep-link / share-link play (balliq://play/<id>). Requires the URL scheme to be
    // registered in Info.plist; the in-app feed works regardless.
    @State private var linkKeep4: Keep4Puzzle?
    @State private var linkWhoAmI: WhoAmIPuzzle?
    @State private var linkID: String?
    @State private var linkAuthor: String?   // creator's username, for the scoring explainer
    @State private var debugCreate = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            LeaguesView()
                .tabItem { Label("Leagues", systemImage: "trophy.fill") }
                .tag(1)

            VersusView()
                .tabItem { Label("Versus", systemImage: "bolt.fill") }
                .tag(2)

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
        .onAppear {
            if let url = DebugLaunch.openURL { Task { await handle(url) } }
            if DebugLaunch.autoOpenCreateKeep4 { debugCreate = true }
            if DebugLaunch.autoOpenStats { selectedTab = 4 }   // Profile tab; it auto-pushes Stats
            if DebugLaunch.autoOpenModeration { selectedTab = 4 }   // ditto for the review queue
            if DebugLaunch.autoOpenLeagues { selectedTab = 1 }
            if DebugLaunch.autoOpenVersus { selectedTab = 2 }
            if DebugLaunch.autoOpenCommunity { selectedTab = 3 }
        }
        .sheet(isPresented: $debugCreate) {
            NavigationStack { CreateKeep4View().environmentObject(container) }
        }
        .fullScreenCover(item: $linkKeep4) { p in
            Keep4GameView(puzzle: p, ranked: false, communityID: linkID, authorName: linkAuthor)
                .environmentObject(container)
        }
        .fullScreenCover(item: $linkWhoAmI) { p in
            WhoAmIGameView(puzzle: p, ranked: false, communityID: linkID).environmentObject(container)
        }
    }

    /// Resolve `balliq://play/<id>` — community puzzles first, then the daily/archive
    /// pools (M13 pre-play sharing shares dailies too; the local fallback works offline).
    private func handle(_ url: URL) async {
        guard url.scheme == "balliq", url.host == "play",
              let id = url.pathComponents.last, !id.isEmpty else { return }
        container.track(.communityPuzzlePlayed, ["source": "link", "puzzle_id": id])
        if let community = container.community {
            linkID = id
            switch await community.load(id: id) {
            case .keep4(let p, let author): linkAuthor = author; linkKeep4 = p; return
            case .whoAmI(let p): linkWhoAmI = p; return
            case .none: break
            }
        }
        // Not a community id: nil out linkID so the game view doesn't log a community play.
        linkID = nil
        linkAuthor = nil
        if let p = await container.puzzles.allKeep4(for: .all).first(where: { $0.id == id }) {
            linkKeep4 = p
        } else if let p = await container.puzzles.allWhoAmI(for: .all).first(where: { $0.id == id }) {
            linkWhoAmI = p
        }
    }
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
