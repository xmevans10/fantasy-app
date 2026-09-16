import XCTest
import SwiftUI
@testable import BallIQ

/// Renders real K4C4 cards as static X posts (1600x900), drawn by `Keep4CardView` itself.
///
/// Same house rule as `OPMSlideGalleryTests`: marketing art shows the shipping component, not an
/// imitation of it, so a restyle of the card is one test run away from a refreshed post. The rows
/// are copied verbatim from the published NFL Week 1 pack (`pack_items` for `nfl-2026-wk01`), so
/// the art is reproducible and every number on it is a real stat line.
///
/// Not run in normal verification (it writes files and needs the network to warm photos):
///
///     xcodebuild test -scheme BallIQ -project BallIQ.xcodeproj \
///       -destination 'platform=iOS Simulator,name=iPhone 17' \
///       -only-testing:BallIQTests/XCardGalleryTests
///
/// then copy the printed `X_CARD:` paths into `marketing/social-kit/06-x-series/`.
@MainActor
final class XCardGalleryTests: XCTestCase {

    /// 1600x900 at scale 3: X's 16:9, sharp on retina.
    private let size = CGSize(width: 1600.0 / 3.0, height: 300)

    private struct Card {
        let file: String
        let player: PlayerSeason
        let teamFullName: String
        let revealed: Bool
    }

    private let store = "https://nhccgufqwndtoasdbkhc.supabase.co/storage/v1/object/public/player-headshots/nfl/"

    private var cards: [Card] {
        [
            // The headline board's top keep, revealed: the card as the answer post shows it.
            Card(file: "k4c4-card-kenneth-walker-week1-revealed",
                 player: PlayerSeason(id: "nfl-kenneth-walker-iii-2026-wk01", name: "Kenneth Walker III",
                                      teamAbbr: "KC", seasonYear: 2026,
                                      stats: [.init(label: "Rush Yds", value: "173"),
                                              .init(label: "Rush TD", value: "1"),
                                              .init(label: "Rec Yds", value: "18"),
                                              .init(label: "Rec TD", value: "1"),
                                              .init(label: "Rec", value: "3")],
                                      grade: 34.1, headshot: store + "c2ca70485b2719fc7bf9.png",
                                      week: 1, opponent: "DEN"),
                 teamFullName: "Kansas City Chiefs", revealed: true),
            // The position board's leader, mid-game: keep or cut?
            Card(file: "k4c4-card-isaiah-likely-week1",
                 player: PlayerSeason(id: "nfl-isaiah-likely-2026-wk01", name: "Isaiah Likely",
                                      teamAbbr: "NYG", seasonYear: 2026,
                                      stats: [.init(label: "Rec Yds", value: "78"),
                                              .init(label: "Rec", value: "8"),
                                              .init(label: "Rec TD", value: "2"),
                                              .init(label: "Yds/Rec", value: "9.8"),
                                              .init(label: "Tgts", value: "8")],
                                      grade: 27.8, headshot: store + "7d20faca18b039c5ca85.png",
                                      week: 1, opponent: "DAL"),
                 teamFullName: "New York Giants", revealed: false),
            // The game of the week's best line.
            Card(file: "k4c4-card-caleb-williams-week1",
                 player: PlayerSeason(id: "nfl-caleb-williams-2026-wk01", name: "Caleb Williams",
                                      teamAbbr: "CHI", seasonYear: 2026,
                                      stats: [.init(label: "Pass Yds", value: "269"),
                                              .init(label: "Pass TD", value: "2"),
                                              .init(label: "INT", value: "0"),
                                              .init(label: "Rush Yds", value: "65"),
                                              .init(label: "Rush TD", value: "2")],
                                      grade: 37.3, headshot: store + "67b3061f4aa202b03709.png",
                                      week: 1, opponent: "CAR"),
                 teamFullName: "Chicago Bears", revealed: false),
        ]
    }

    /// Both size buckets for photo and crest, for the reason `OPMSlideGalleryTests` documents:
    /// the card derives its image sizes from measured layout, and a warm miss draws the monogram.
    private func warm(_ player: PlayerSeason) async {
        if let headshot = player.headshot, let url = URL(string: headshot) {
            for bucket in [AppImagePipeline.cardWarmSize, AppImagePipeline.warmSize] {
                _ = await ImageCache.shared.image(for: url, targetSize: bucket)
            }
        }
        if let crest = Sport.nfl.teamLogoURL(forAbbr: player.teamAbbr) {
            for bucket in [AppImagePipeline.crestWarmSize, AppImagePipeline.cardWarmSize] {
                _ = await ImageCache.shared.image(for: crest, targetSize: bucket)
            }
        }
    }

    func testRenderXCards() async throws {
        for card in cards {
            await warm(card.player)
            // Laid out at the board's real card size and then scaled, never squeezed: the card's
            // proportions drive its image sizes (see OPMSlideGalleryTests.testRenderCardSlide).
            let poster = ZStack {
                Color.appBackground
                Keep4CardView(player: card.player, sport: .nfl,
                              assignment: card.revealed ? .keep : nil,
                              revealCorrect: card.revealed ? true : nil,
                              foil: card.revealed, fillsHeight: true,
                              teamFullName: card.teamFullName) { _ in }
                    .frame(width: 370, height: 470)
                    .scaleEffect((size.height - 24) / 470)
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: poster)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage, "\(card.file) failed to render")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(card.file)-1600x900.png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("X_CARD: \(url.path)")
        }
    }
}
