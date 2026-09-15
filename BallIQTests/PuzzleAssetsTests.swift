import XCTest
import UIKit
@testable import BallIQ

/// Locks the puzzle asset bundle (2026-09-14, "we can't have ANY latency for headshots"): what a
/// board declares it needs, and the cache behaviour that makes a warm actually count at render.
/// Cache cases use `file://` images written per test, which `ImageCache.fetch` reads directly, so
/// they exercise the real fetch/decode/store path without the network.
final class PuzzleAssetsTests: XCTestCase {

    // MARK: - Bundle contents

    private func keep4(headshots: [String?]) -> Keep4Puzzle {
        let players = headshots.enumerated().map { i, headshot in
            PlayerSeason(id: "p\(i)", name: "P \(i)", teamAbbr: i.isMultiple(of: 2) ? "KC" : "BUF",
                         seasonYear: 2020, stats: [], grade: Double(i), headshot: headshot)
        }
        return Keep4Puzzle(id: "k", theme: "T", sport: .nfl, players: players)
    }

    func testKeep4BundleHasEveryHeadshotAtTheBoardsHeroBucket() {
        let urls = (0..<8).map { "https://cdn.example/h\($0).png" }
        let assets = PuzzleAssets(keep4: keep4(headshots: urls))
        let heroBucket = AppImagePipeline.pixelBucket(for: AppImagePipeline.cardWarmSize)
        let headshots = assets.images.filter { $0.url.absoluteString.hasPrefix("https://cdn.example/") }
        XCTAssertEqual(headshots.map(\.url.absoluteString), urls)
        XCTAssertTrue(headshots.allSatisfy { AppImagePipeline.pixelBucket(for: $0.size) == heroBucket })
        // The board draws up to 140 pt, so anything smaller would warm an entry the card can't use.
        XCTAssertGreaterThanOrEqual(heroBucket, AppImagePipeline.pixelBucket(for: CGSize(width: 140, height: 140)))
    }

    /// Blank strings are the catalog's "no photo" marker; the card shows a monogram for them, so
    /// they are not assets and must never hold the board back.
    func testKeep4BundleSkipsMissingAndBlankHeadshots() {
        let assets = PuzzleAssets(keep4: keep4(headshots: ["https://cdn.example/a.png", nil, "", " "]))
        let headshots = assets.images.filter { $0.url.absoluteString.hasPrefix("https://cdn.example/") }
        XCTAssertEqual(headshots.map(\.url.absoluteString), ["https://cdn.example/a.png"])
    }

    /// 8 cards across two franchises are two crests, not eight.
    func testKeep4BundleDedupesSharedCrests() {
        let assets = PuzzleAssets(keep4: keep4(headshots: Array(repeating: nil, count: 8)))
        let expected = Set(["KC", "BUF"].compactMap { Sport.nfl.teamLogoURL(forAbbr: $0) })
        XCTAssertEqual(Set(assets.images.map(\.url)), expected)
        XCTAssertEqual(assets.images.count, expected.count)
    }

    /// `CareerPathTimeline` draws no crest for a historical stint (the code is a different
    /// franchise today), so warming one would be traffic for an image nobody sees.
    func testJourneymanBundleMirrorsTheTimeline() {
        let puzzle = JourneymanPuzzle(
            id: "j", sport: .nfl,
            stints: [
                .init(order: 1, teamAbbr: "HOU", teamName: "Oilers", league: "",
                      firstYear: 1990, lastYear: 1995, historical: true),
                .init(order: 2, teamAbbr: "NO", teamName: "Saints", league: "",
                      firstYear: 1996, lastYear: 2000),
            ],
            answer: .init(canonical: "X", aliases: []),
            difficulty: .medium, position: "QB", headshot: "https://cdn.example/answer.png")
        let urls = PuzzleAssets(journeyman: puzzle).images.map(\.url)
        XCTAssertTrue(urls.contains(URL(string: "https://cdn.example/answer.png")!))
        if let hou = Sport.nfl.teamLogoURL(forAbbr: "HOU", league: "") {
            XCTAssertFalse(urls.contains(hou), "historical stint's crest must not be in the bundle")
        }
        if let saints = Sport.nfl.teamLogoURL(forAbbr: "NO", league: "") {
            XCTAssertTrue(urls.contains(saints))
        }
    }

    func testWhoAmIBundleIsOnlyTheResolvedAnswerPhoto() {
        XCTAssertTrue(PuzzleAssets(whoAmIAnswer: nil).images.isEmpty)
        let row = CatalogSeason(id: "r", sport: .nba, name: "A", teamAbbr: "X", seasonYear: 2000,
                                position: "G", stats: [:], headshot: "https://cdn.example/w.png")
        XCTAssertEqual(PuzzleAssets(whoAmIAnswer: row).images.map(\.url.absoluteString),
                       ["https://cdn.example/w.png"])
    }

    // MARK: - Cache behaviour

    private func writeImage(side: CGFloat = 600) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("puzzle-assets-\(UUID().uuidString).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The Keep4 card's headshot is 56–140 pt depending on screen height, so a device can ask for
    /// the small bucket after the warm filled the large one. That must be a hit.
    func testALargerWarmServesASmallerDraw() async throws {
        let url = try writeImage()
        let big = await ImageCache.shared.image(for: url, targetSize: AppImagePipeline.cardWarmSize)
        XCTAssertNotNil(big)
        let small = AppImagePipeline.pixelBucket(for: CGSize(width: 48, height: 48))
        XCTAssertNotNil(ImageCache.shared.cached(url, pixelSize: small))
    }

    /// The reverse is not true: a small decode stretched onto the hero card would be blurry.
    func testASmallerWarmDoesNotServeALargerDraw() async throws {
        let url = try writeImage()
        _ = await ImageCache.shared.image(for: url, targetSize: CGSize(width: 48, height: 48))
        let large = AppImagePipeline.pixelBucket(for: AppImagePipeline.cardWarmSize)
        let small = AppImagePipeline.pixelBucket(for: CGSize(width: 48, height: 48))
        guard large > small else { return }   // single-bucket ladder: nothing to distinguish
        XCTAssertNil(ImageCache.shared.cached(url, pixelSize: large))
    }

    func testPrepareLeavesTheWholeBundleCached() async throws {
        let urls = try (0..<3).map { _ in try writeImage() }
        let assets = PuzzleAssets(images: urls.map { .init(url: $0, size: AppImagePipeline.cardWarmSize) })
        XCTAssertFalse(assets.isCached)
        let landed = await assets.prepare(timeout: 5)
        XCTAssertTrue(landed)
        XCTAssertTrue(assets.isCached, "a gate built after prepare must open on its first frame")
    }

    /// The gate's cap: an image that never arrives releases the board at the timeout instead of
    /// holding it for URLSession's 60 s default. 10.255.255.1 is non-routable, so the connect hangs.
    func testPrepareGivesUpAtTheTimeout() async {
        let assets = PuzzleAssets(images: [.init(url: URL(string: "http://10.255.255.1/\(UUID().uuidString).png")!,
                                                 size: AppImagePipeline.warmSize)])
        let start = Date()
        let landed = await assets.prepare(timeout: 0.3)
        XCTAssertFalse(landed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Replaces the old permanent "already warmed" set, which skipped any URL it had seen once. An
    /// entry evicted (or a warm that failed) after that could never be warmed again.
    func testAPrefetchAfterEvictionWarmsAgain() async throws {
        let url = try writeImage()
        let assets = PuzzleAssets(images: [.init(url: url, size: AppImagePipeline.warmSize)])
        await assets.prepare(timeout: 5)
        XCTAssertTrue(assets.isCached)
        ImageCache.removeAllForTesting()
        XCTAssertFalse(assets.isCached)
        assets.prefetch()
        let deadline = Date().addingTimeInterval(5)
        while !assets.isCached, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(assets.isCached)
    }
}
