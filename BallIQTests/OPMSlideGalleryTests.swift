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
    ///
    /// Copied verbatim from `nfl-qb-mvp-00`, five stats and all. The first version of this
    /// fixture was pulled by a script filtering for a 4-stat line and landed on the one variant
    /// of this player-season that drops INT (`nfl-total-fantasy-00`) — a real row, but an
    /// atypical one, and a QB card with no interceptions reads as a bug to anyone who knows the
    /// sport. Five stats is also the catalog's dominant shape (284 of the 400 bundled cards), so
    /// this renders the 3+2 layout most players actually see.
    private var sampleCard: PlayerSeason {
        PlayerSeason(
            id: "nfl-lamar-jackson-2024",
            name: "Lamar Jackson",
            teamAbbr: "BAL",
            seasonYear: 2024,
            stats: [.init(label: "Pass Yds", value: "4,172"),
                    .init(label: "Pass TD", value: "41"),
                    .init(label: "INT", value: "4"),
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
        // Both buckets here too, for the same reason as the headshot above: the crest is drawn
        // huge as the card's watermark, and which bucket it *requests* depends on whether the
        // watermark pins its fetch size. Warming one and rendering the other is why the first
        // version of this poster shipped with an empty disc where the Ravens shield should be.
        if let crest = Sport.nfl.teamLogoURL(forAbbr: card.teamAbbr) {
            for size in [AppImagePipeline.crestWarmSize, AppImagePipeline.cardWarmSize] {
                _ = await ImageCache.shared.image(for: crest, targetSize: size)
            }
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

    /// Slide — Puzzle Blitz, drawn by `BlitzRoundList`, the component the result screen uses.
    ///
    /// This one earns its place by showing the thing the mode *is*: four different formats, one
    /// run, one score. A format tile would only have said the name.
    func testRenderBlitzSlide() async throws {
        let rounds: [BlitzRoundResult] = [
            .init(format: .keep4, sport: .nfl, puzzleID: "opm-1",
                  performance: 0.875, cleared: true, elapsed: 74),
            .init(format: .whoami, sport: .nba, puzzleID: "opm-2",
                  performance: 0.8, cleared: true, elapsed: 31),
            .init(format: .overunder, sport: .baseball, puzzleID: "opm-3",
                  performance: 1.0, cleared: true, elapsed: 9),
            .init(format: .journeyman, sport: .soccer, puzzleID: "opm-4",
                  performance: 0.6, cleared: true, elapsed: 46),
        ]
        let summary = BlitzRunSummary(config: .default, rounds: rounds, elapsed: 180)
        let poster = ZStack {
            Color.appBackground
            BlitzRoundList(summary: summary)
                .padding(20)
        }
        try write(poster, named: "opm-puzzle-blitz")
    }

    /// Slide 2 — Home's formats grid, drawn by the same `FormatGridItem` the page uses, in the
    /// same two-column layout, so the slide matches what the player sees when they close it.
    func testRenderFormatsSlide() async throws {
        // **Every** format, not a prefix. The first version took `.prefix(6)`, which dropped
        // Versus and Puzzle Blitz — so a slide captioned "every way to play" was missing two of
        // the eight, one of them the new mode slide 1 is about.
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        let poster = ZStack {
            Color.appBackground
            // Laid out at the height eight tiles actually need, then scaled into the square —
            // same reasoning as the card slide: squeezing the frame would restyle the tiles
            // rather than shrink them.
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(GameFormat.all) { format in
                    FormatGridItem(format: format) {}
                }
            }
            .padding(20)
            .frame(width: 440, height: 540)
            // Scaled to a little under the square so the top and bottom rows keep a margin —
            // Notelet clips media into a rounded rect, and a tile flush to the edge loses its
            // corner to the clip.
            .scaleEffect((side - 30) / 540)
        }
        try write(poster, named: "opm-formats-first")
    }

}
