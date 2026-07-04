import XCTest
import SwiftUI
@testable import BallIQ

/// Renders every scoring-kind visual variant — the three card badges and the three explainer
/// chips (including the two-line wrap case) — to a PNG for eyeballing, since the era/custom
/// states can't be reached by a single non-interactive simulator screenshot. Doubles as a
/// smoke test that these views render at all.
@MainActor
final class ScoringGalleryTests: XCTestCase {

    func testRenderGallery() throws {
        let gallery = VStack(alignment: .leading, spacing: 14) {
            DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill", sport: .nfl,
                          title: "All-time fantasy seasons — any position",
                          subtitle: "8 seasons", scoring: .ppr, completed: false) {}
            DailyGameCard(formatName: "K4C4", symbol: "rectangle.stack.fill", sport: .nfl,
                          title: "Best seasons of all time — era-adjusted",
                          subtitle: "8 seasons · archive", scoring: .era, completed: false) {}
            DailyGameCard(formatName: "K4C4", symbol: "football.fill", sport: .nfl,
                          title: "My sleeper TE hall of fame",
                          subtitle: "12 plays · by @gridironguru",
                          description: "Seasons nobody saw coming.",
                          scoring: .vibes, completed: false,
                          accent: .warningFill, onAccent: .onWarning,
                          bodyFill: .warningBg) {}
            ScoringNoteChip(kind: .ppr, sport: .nfl)
            ScoringNoteChip(kind: .era, sport: .nfl)
            ScoringNoteChip(kind: .vibes, sport: .nfl, author: "gridironguru")
        }
        .padding(20)
        .frame(width: 393)
        .background(Color.appBackground)

        let renderer = ImageRenderer(content: gallery)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "scoring gallery failed to render")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scoring_gallery.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("SCORING_GALLERY: \(url.path)")
    }
}
