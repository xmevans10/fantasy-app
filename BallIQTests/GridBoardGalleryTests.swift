import XCTest
import SwiftUI
@testable import BallIQ

/// Renders the live Grid board for each new archetype, so the symmetric-axis layout can be
/// eyeballed before any of these shapes exist in production content.
///
/// This is the only honest way to see them right now: the generator emits `rows`/`cols` boards
/// today, but pushing one to Supabase would break every user still on the shipped App Store
/// build (a teams x teams board has no legacy `rowTeams`/`colDecades` fallback, so an old client
/// renders "No Grid today"). Content rollout has to wait for the client build — see
/// docs/grid-axes-research.md. Same hosted-window/ImageRenderer pattern as
/// `GridGuessGalleryTests`; prints each PNG path as `GRID_BOARD_GALLERY:`.
///
/// Labels are the longest ones **that sport's own catalog** can produce, so each board stresses
/// the layout (AGENTS.md §5: check the outlier content) while still reading as a real board.
///
/// A first version of this file mixed the longest labels from across every sport onto one NFL
/// board — "WSH / HOU / PHI" x "Midfielders / 30+ Stolen Bases / 2000s" — which looked exactly
/// like a generator bug and prompted "these aren't football things???". The generator cannot
/// actually do that (`grid_axes` keys every catalog by sport, and
/// `test_a_board_never_shows_another_sports_axis` pins it at the generation level), but a
/// fixture that *looks* broken is worse than no fixture: it costs someone a real investigation.
/// Keep every board here self-consistent with its sport.
@MainActor
final class GridBoardGalleryTests: XCTestCase {

    private func board(archetype: String,
                       rows: [GridPuzzle.GridAxis],
                       cols: [GridPuzzle.GridAxis],
                       sport: Sport = .nfl) -> GridPuzzle {
        GridPuzzle(sport: sport, rows: rows, cols: cols,
                   cells: (0..<9).map { i in
                       GridPuzzle.GridCell(validAnswerIds: ["id-\(i)"],
                                           validAnswerNames: ["Player \(i)"],
                                           rarityStars: (i % 5) + 1)
                   },
                   archetype: archetype)
    }

    /// Team axes carry a raw `abbr` distinct from their rendered label, mirroring real content:
    /// the label may be league-qualified ("MCI-ENG") while colors and crests key on "MCI".
    private func axis(_ kind: GridPuzzle.GridAxis.Kind, _ label: String) -> GridPuzzle.GridAxis {
        guard kind == .team else { return GridPuzzle.GridAxis(kind: kind, label: label) }
        let parts = label.split(separator: "-", maxSplits: 1)
        return GridPuzzle.GridAxis(kind: .team, label: label, abbr: String(parts[0]),
                                   league: parts.count > 1 ? String(parts[1]) : nil)
    }

    func testRenderEveryArchetype() async throws {
        let boards: [(String, GridPuzzle)] = [
            ("teams-x-decades", board(
                archetype: "teams-x-decades",
                rows: [axis(.team, "KC"), axis(.team, "DAL"), axis(.team, "SEA")],
                cols: [axis(.decade, "1980s"), axis(.decade, "1990s"), axis(.decade, "2010s")])),
            // The longest stat labels in the catalog — this is the layout most at risk.
            ("teams-x-stats", board(
                archetype: "teams-x-stats",
                rows: [axis(.team, "KC"), axis(.team, "DAL"), axis(.team, "SEA")],
                cols: [axis(.stat, "1,000+ Rush Yds"), axis(.stat, "4,000+ Pass Yds"),
                       axis(.stat, "80+ Receptions")])),
            ("teams-x-teams", board(
                archetype: "teams-x-teams",
                rows: [axis(.team, "MIA"), axis(.team, "SEA"), axis(.team, "LA")],
                cols: [axis(.team, "CAR"), axis(.team, "PIT"), axis(.team, "JAX")])),
            ("teams-x-mixed", board(
                archetype: "teams-x-mixed",
                rows: [axis(.team, "WSH"), axis(.team, "HOU"), axis(.team, "PHI")],
                cols: [axis(.position, "QB"), axis(.stat, "1,400+ Rec Yds"),
                       axis(.decade, "2000s")])),
            // Soccer team x team with league-qualified labels — the widest text a team chip ever
            // has to hold ("MCI-ENG" vs a bare "KC"), and the case that would truncate first.
            ("soccer-teams-x-teams", board(
                archetype: "teams-x-teams",
                rows: [axis(.team, "MCI-ENG"), axis(.team, "TOR-ITA"), axis(.team, "GAL-TUR")],
                cols: [axis(.team, "MCI-AUS"), axis(.team, "TOR-USA"), axis(.team, "PATH-GRE")],
                sport: .soccer)),
            // A non-NFL board too, so the shared layout isn't only ever checked against one
            // sport's label lengths — baseball's are the longest in the catalog.
            ("baseball-teams-x-mixed", board(
                archetype: "teams-x-mixed",
                rows: [axis(.team, "NYY"), axis(.team, "LAD"), axis(.team, "BOS")],
                cols: [axis(.position, "Pitchers"), axis(.stat, "30+ Stolen Bases"),
                       axis(.stat, "Sub-3.00 ERA")],
                sport: .baseball)),
            ("nba-completed", board(archetype: "teams-x-stats",
                rows: [axis(.team, "MIL"), axis(.team, "OKC"), axis(.team, "LAL")],
                cols: [axis(.stat, "30+ Points Per Game"), axis(.stat, "10+ Rebounds Per Game"), axis(.stat, "10+ Assists Per Game")], sport: .nba)),
            ("tennis-decades-x-stats", board(archetype: "decades-x-stats",
                rows: [axis(.decade, "1990s"), axis(.decade, "2000s"), axis(.decade, "2020s")],
                cols: [axis(.stat, "Grand Slam champion"), axis(.stat, "40+ Match Wins"), axis(.stat, "70%+ Win Percentage")], sport: .tennis)),
        ]

        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first,
            "no window in hosted test app")

        for (name, puzzle) in boards {
            let completed = name == "nba-completed"
            let view = GridBoardGalleryHarness(puzzle: puzzle,
                solved: completed ? [0: "Giannis Antetokounmpo", 4: "Shai Gilgeous-Alexander"] : [:],
                completed: completed)
            let host = UIHostingController(rootView: view.environmentObject(RepositoryContainer.make()))
            let previous = window.rootViewController
            window.rootViewController = host
            defer { window.rootViewController = previous }

            for _ in 0..<3 {
                await Task.yield()
                try await Task.sleep(nanoseconds: 300_000_000)
            }

            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("grid_board_\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("GRID_BOARD_GALLERY:\(url.path)")
        }
    }
}

/// Renders `SpinRevealView` in its **pending** state — on screen, reels rolling, no landed target
/// yet. That state is new (2026-07-27) and is what the roster fetch now hides behind, so it needs
/// looking at: it's the frame a player sees for the first ~0.4s of every spin.
@MainActor
final class SpinRevealPendingGalleryTests: XCTestCase {

    func testRenderPendingReel() async throws {
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first,
            "no window in hosted test app")

        // A constant nil binding pins the reel in the waiting state so it can be captured; in the
        // app this resolves as soon as `spinUntilFillable` vets a combo.
        let view = SpinRevealView(target: .constant(nil),
                                  roundLabel: "Round 3 of 6",
                                  realDecoyTeams: ["KC", "DAL", "SEA", "GB", "NYG", "CHI"],
                                  realDecoyYears: ["1994", "2003", "2011", "2019", "2022"],
                                  abbreviated: true) {}
        let host = UIHostingController(rootView: view.environmentObject(RepositoryContainer.make()))
        let previous = window.rootViewController
        window.rootViewController = host
        defer { window.rootViewController = previous }

        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spin_reveal_pending.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("GRID_BOARD_GALLERY:\(url.path)")
    }
}

/// Minimal stand-in for `GridGameView`'s board section. `GridGameView` itself can't be hosted
/// here — it fetches its puzzle from the repository on `.task` and would overwrite any injected
/// content — so the shared production board is rendered against a fixed puzzle.
private struct GridBoardGalleryHarness: View {
    let puzzle: GridPuzzle
    var solved: [Int: String] = [:]
    var completed = false

    var body: some View {
        VStack(spacing: 0) {
            Text(puzzle.archetype.uppercased())
                .font(.label12).foregroundStyle(Color.proText).padding(.top, 60)
            Spacer(minLength: 0)
            layout.padding(16)
            Spacer(minLength: 0)
            Text(puzzle.instructions)
                .font(.label11).foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    private var layout: some View {
        GridBoardPresentation(puzzle: puzzle, solved: solved, completed: completed) { _ in }
    }
}
