import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var container: RepositoryContainer

    // Deep-link / share-link play (balliq://play/<id>). Requires the URL scheme to be
    // registered in Info.plist; the in-app feed works regardless.
    @State private var linkKeep4: Keep4Puzzle?
    @State private var linkWhoAmI: WhoAmIPuzzle?
    @State private var linkID: String?
    @State private var debugCreate = false

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            PlaceholderView(title: "Leagues",
                            symbol: "trophy.fill",
                            blurb: "Weekly cohorts, promotion & relegation, and season countdowns land here.")
                .tabItem { Label("Leagues", systemImage: "trophy.fill") }

            CommunityView()
                .tabItem { Label("Community", systemImage: "square.stack.3d.up.fill") }

            PlaceholderView(title: "Stats",
                            symbol: "chart.line.uptrend.xyaxis",
                            blurb: "Rating graphs, format accuracy, and streak history will live here.")
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .onOpenURL { url in Task { await handle(url) } }
        .onAppear { if DebugLaunch.autoOpenCreateKeep4 { debugCreate = true } }
        .sheet(isPresented: $debugCreate) {
            NavigationStack { CreateKeep4View().environmentObject(container) }
        }
        .fullScreenCover(item: $linkKeep4) { p in
            Keep4GameView(puzzle: p, ranked: false, communityID: linkID).environmentObject(container)
        }
        .fullScreenCover(item: $linkWhoAmI) { p in
            WhoAmIGameView(puzzle: p, ranked: false, communityID: linkID).environmentObject(container)
        }
    }

    /// Resolve `balliq://play/<id>` to a community puzzle and present it.
    private func handle(_ url: URL) async {
        guard url.scheme == "balliq", url.host == "play",
              let id = url.pathComponents.last, !id.isEmpty,
              let community = container.community else { return }
        linkID = id
        switch await community.load(id: id) {
        case .keep4(let p): linkKeep4 = p
        case .whoAmI(let p): linkWhoAmI = p
        case .none: break
        }
    }
}

/// Decides between onboarding and the main app.
struct RootView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some View {
        if hasOnboarded {
            ContentView()
        } else {
            OnboardingView()
        }
    }
}

#Preview {
    let container = RepositoryContainer.make(client: nil)
    return ContentView()
        .environmentObject(container)
        .environmentObject(container.auth)
}
