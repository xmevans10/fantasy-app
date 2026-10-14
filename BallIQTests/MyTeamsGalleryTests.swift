import XCTest
import SwiftUI
@testable import BallIQ

@MainActor
final class MyTeamsGalleryTests: XCTestCase {
    func testNativeTeamFlowAndLargeText() async throws {
        let container = RepositoryContainer(auth: AuthService(client: nil), client: nil, store: StoreService(fetchStub: { _ in [] }))
        await container.saveFavoriteTeams(FavoriteTeams(teams: ["nfl":"NO"]))
        let boards = TeamPuzzleRepository.bundled()
        let starter = try XCTUnwrap(boards.first)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first)
        let original = window.rootViewController
        defer { window.rootViewController = original }
        func capture<V: View>(_ view: V, _ name: String) async throws {
            window.rootViewController = UIHostingController(rootView: view.environmentObject(container).environmentObject(container.auth).environmentObject(MomentPresenter()))
            for _ in 0..<3 { await Task.yield(); try await Task.sleep(nanoseconds: 250_000_000) }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("myteams_\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("MYTEAMS_GALLERY:\(url.path)")
        }
        try await capture(HomeView(selectedTab: .constant(0)), "home")
        try await capture(NavigationStack { MyTeamHubView(sport: .nfl, team: "NO", initialBoards: boards) }, "hub")
        try await capture(NavigationStack { MyTeamHubView(sport: .nfl, team: "NO", initialBoards: boards) }.environment(\.dynamicTypeSize, .accessibility3), "large_text")
        try await capture(TeamPuzzleSession(board: starter, inventory: boards), "game")
        let placement = Dictionary(uniqueKeysWithValues: starter.content.players.map { ($0.id, starter.content.correctKeepIDs.contains($0.id) ? Pile.keep : .cut) })
        let rewards = await container.completeTeam(puzzle: starter.content, placement: placement, detail: .init(mode: .archive))
        XCTAssertGreaterThan(rewards.xpEarned, 0)
        let duplicate = await container.completeTeam(puzzle: starter.content, placement: placement, detail: .init(mode: .archive))
        XCTAssertEqual(duplicate.xpEarned, 0)
        try await capture(Keep4ResultView(puzzle: starter.content, placement: placement, result: Keep4Scoring.score(puzzle: starter.content, placement: placement), rewards: rewards, onDone: {}).environment(\.teamPlayNext, {}), "result")
        try await capture(NavigationStack { MyTeamHubView(sport: .nfl, team: "NO", initialBoards: boards) }, "completed")
        container.teamGames.reset()
    }
}
