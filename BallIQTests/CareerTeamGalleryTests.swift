import XCTest
import SwiftUI
@testable import BallIQ

/// Render the real components at phone widths, including long names and missing photos.
@MainActor
final class CareerTeamGalleryTests: XCTestCase {
    func testRenderCareerAndTeamComponents() throws {
        for xp in [0, 399, 8100, 27100, 84100] {
            try capture(CareerProgressCard(xp: xp), name: "career-\(xp)", width: 343, height: 230)
        }
        for (sport, team) in [(Sport.nfl, "NYJ"), (.nba, "DET"), (.baseball, "BOS"), (.soccer, "PSG")] {
            try capture(TeamHubHeader(sport: sport, teamAbbr: team,
                                      subtitle: "One club. Eight seasons. Keep the best four."),
                        name: "team-\(sport.rawValue)", width: 343, height: 180)
        }
    }
    func testRenderPortraits() async throws {
        let repo = LocalPuzzleRepository()
        for sport in Sport.allCases {
            let pool = await repo.allKeep4(for: SportFilter(rawValue: sport.rawValue) ?? .all)
            let player = pool.first?.players.first ?? PlayerSeason(
                id: "fallback", name: "A Player With A Long Name", teamAbbr: "",
                seasonYear: 2024, stats: [.init(label: "Games", value: "80")], grade: 1)
            if let url = player.headshot.flatMap(URL.init(string:)) {
                for size: CGFloat in [192, 384] {
                    _ = await ImageCache.shared.image(for: url, targetSize: CGSize(width: size, height: size))
                }
            }
            for height: CGFloat in [330, 520] {
                try capture(Keep4CardView(player: player, sport: sport, assignment: nil,
                                         revealCorrect: nil, fillsHeight: true,
                                         teamFullName: "A LONG FRANCHISE NAME") { _ in },
                            name: "portrait-\(sport.rawValue)-\(Int(height))", width: 343, height: height)
            }
        }
        let fallback = PlayerSeason(id: "missing", name: "Shai Gilgeous-Alexander", teamAbbr: "",
                                    seasonYear: 2024, stats: [.init(label: "Points", value: "30.1")], grade: 1)
        try capture(Keep4CardView(player: fallback, sport: .nba, assignment: nil,
                                 revealCorrect: nil, fillsHeight: true) { _ in },
                    name: "portrait-missing-longname", width: 343, height: 330)
    }
    func testRenderHomeAndTeamHub() async throws {
        let defaults = UserDefaults.standard
        let previousFavorites = defaults.object(forKey: "guestFavoriteTeams")
        defer { defaults.set(previousFavorites, forKey: "guestFavoriteTeams") }
        let container = RepositoryContainer(auth: AuthService(client: nil), client: nil,
                                             store: StoreService(fetchStub: { _ in [] }))
        await container.saveFavoriteTeams(FavoriteTeams(teams: ["nfl": "NYJ"]))
        try await captureHosted(HomeView(selectedTab: .constant(0))
            .environmentObject(container).environmentObject(MomentPresenter()), name: "home")
        try await captureHosted(NavigationStack {
            TeamHubView(sport: .nfl, teamAbbr: "NYJ").environmentObject(container)
        }, name: "team-hub-empty")
    }

    private func captureHosted<V: View>(_ view: V, name: String) async throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first)
        let original = window.rootViewController
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        defer { window.rootViewController = original }
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("career-team-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("CAREER_TEAM_GALLERY: \(url.path)")
    }

    private func capture<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).padding(8)
            .background(Color.appBackground))
        renderer.scale = 2
        let data = try XCTUnwrap(renderer.uiImage?.pngData())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("career-team-\(name).png")
        try data.write(to: url)
        print("CAREER_TEAM_GALLERY: \(url.path)")
    }
}
