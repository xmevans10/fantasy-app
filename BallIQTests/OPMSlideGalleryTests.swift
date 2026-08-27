import XCTest
import SwiftUI
@testable import BallIQ

/// Generates the artwork for the in-app update messages (see `UpdateNotes`), by rendering the
/// **real shipping views** to PNGs rather than by taking screenshots.
///
/// That is the point, and it is the house rule for this surface: an OPM slide must carry a
/// component from the code the update actually changed. A screenshot satisfies that on the day
/// it is taken and quietly stops being true afterwards — the card gets restyled, the tile gets
/// a new colour, and the release notes go on advertising a version of the app nobody is running.
/// Rendering `Keep4CardView` and `FormatGridItem` here means regenerating is a test run, and a
/// diff in `BallIQ/Resources/OPM/` is visible in review.
///
/// Not run as part of normal verification — it writes files and needs the network to warm the
/// card's photo. Regenerate deliberately:
///
///     xcodebuild test -scheme BallIQ -project BallIQ.xcodeproj \
///       -destination 'platform=iOS Simulator,name=iPhone 17' \
///       -only-testing:BallIQTests/OPMSlideGalleryTests
///
/// then copy the paths it prints (`OPM_SLIDE:`) into `BallIQ/Resources/OPM/`.
///
/// Sizing: Notelet renders media into a **square**, `scaledToFill`, so anything non-square is
/// cropped on both edges. Every poster here is authored square for that reason.
@MainActor
final class OPMSlideGalleryTests: XCTestCase {

    private let side: CGFloat = 440

    /// Hardcoded rather than read from the bundled puzzles: the art has to be reproducible, and
    /// content churn would otherwise silently redraw the slide. The *view* is the shipping one —
    /// that is what the rule is about — while the row it draws is a fixture.
    private var sampleCard: PlayerSeason {
        PlayerSeason(
            id: "nfl-lamar-jackson-2024",
            name: "Lamar Jackson",
            teamAbbr: "BAL",
            seasonYear: 2024,
            stats: [.init(label: "Pass Yds", value: "4,172"),
                    .init(label: "Pass TD", value: "41"),
                    .init(label: "Rush Yds", value: "915"),
                    .init(label: "Rush TD", value: "4")],
            grade: 438.4,
            headshot: "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/cruqs6qpbykh7a2whd7p"
        )
    }

    /// `RemoteImage` seeds itself from a synchronous cache probe in `init`, so an image that is
    /// already decoded renders on the first frame — which is exactly what `ImageRenderer` gets.
    /// Without this the poster would draw the initials monogram and the abbreviation chip (the
    /// app's correct offline fallbacks, and a terrible advert for a card redesign).
    private func warmCardImages() async {
        let card = sampleCard
        // Both buckets, because the poster's card is not necessarily the phone's card: the
        // headshot size is derived from the band's measured height, so a shorter card asks for
        // 192 where the board asks for 384. Warming one and rendering the other is what drew the
        // initials monogram on the first attempt at this slide.
        for size in [AppImagePipeline.cardWarmSize, AppImagePipeline.warmSize] {
            if let headshot = card.headshot, let url = URL(string: headshot) {
                _ = await ImageCache.shared.image(for: url, targetSize: size)
            }
        }
        if let crest = Sport.nfl.teamLogoURL(forAbbr: card.teamAbbr) {
            _ = await ImageCache.shared.image(for: crest, targetSize: AppImagePipeline.crestWarmSize)
        }
    }

    private func write(_ view: some View, named name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "\(name) failed to render")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("OPM_SLIDE: \(url.path)")
    }

    /// Slide 1 — the redesigned K4C4 card, drawn by `Keep4CardView` itself in its board
    /// (`fillsHeight`) configuration, which is the thing that changed.
    func testRenderCardSlide() async throws {
        await warmCardImages()
        // Laid out at the board's real size and *then* scaled down, rather than squeezed into
        // the square. The card's proportions are load-bearing — the headshot size and the crest
        // watermark are both derived from the band's measured height — so shrinking the frame
        // does not shrink the card, it redesigns it. At 330pt the band collapsed to 56 and the
        // poster advertised a layout the app never draws.
        let poster = ZStack {
            Color.appBackground
            Keep4CardView(player: sampleCard, sport: .nfl, assignment: nil, revealCorrect: nil,
                          fillsHeight: true, teamFullName: "Baltimore Ravens") { _ in }
                .frame(width: 370, height: 470)
                .scaleEffect(0.84)
        }
        try write(poster, named: "opm-card-redesign")
    }

    /// Slide 2 — Home's formats grid, drawn by the same `FormatGridItem` the page uses, in the
    /// same two-column layout, so the slide matches what the player sees when they close it.
    func testRenderFormatsSlide() async throws {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        let poster = ZStack {
            Color.appBackground
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(GameFormat.all.prefix(6))) { format in
                    FormatGridItem(format: format) {}
                }
            }
            .padding(22)
        }
        try write(poster, named: "opm-formats-first")
    }

}
