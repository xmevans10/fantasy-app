import XCTest
import SwiftUI
@testable import BallIQ

/// Renders the live GridGuessSheet with the autocomplete populated (pre-seeded query), so the
/// player-name popup layout can be eyeballed non-interactively — the simulator can't type into
/// the field. Same hosted-window/ImageRenderer pattern as PaywallGalleryTests; prints the PNG
/// path as `GRID_GUESS_GALLERY:`.
@MainActor
final class GridGuessGalleryTests: XCTestCase {

    func testRenderGuessSheetWithSuggestions() async throws {
        let names = [
            "Sam Darnold", "Darren Waller", "Stefon Diggs", "Saquon Barkley",
            "Patrick Mahomes", "Peyton Manning", "Eli Manning", "D.K. Metcalf",
            "Darius Slay", "Darrelle Revis", "Dareon Nixon",
        ]
        let sheet = GridGuessSheet(
            prompt: "SEATTLE SEAHAWKS in the 2020s",
            names: names,
            initialText: "dar",
            onGuess: { _ in },
            onCancel: {}
        )

        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first,
            "no window in hosted test app")
        let host = UIHostingController(rootView: sheet.environmentObject(RepositoryContainer.make()))
        let previous = window.rootViewController
        window.rootViewController = host
        defer { window.rootViewController = previous }

        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 350_000_000)
        }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grid_guess_gallery.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("GRID_GUESS_GALLERY: \(url.path)")

        // Sanity: the same ranking the view uses surfaces the Dar* names for this query.
        XCTAssertTrue(GridGuessSheet.rank(query: "dar", names: names).contains("Sam Darnold"))
    }
}
