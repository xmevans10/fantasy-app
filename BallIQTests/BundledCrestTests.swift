import XCTest
@testable import BallIQ

/// Pins the bundled crest set — the one image class this app ships rather than fetches.
///
/// The trade, for the record: 311 crests at 96px WebP is 1.8 MB and covers a logo that appears on
/// essentially every board in every format, forever, offline. The 41,236 distinct headshots are
/// ~250 MB at the same treatment, which is past the App Store's cellular-download limit and would
/// *still* need the network for every player added after the build — so they stay remote and get
/// resized at the edge instead (`ImageURLTransformTests`).
@MainActor
final class BundledCrestTests: XCTestCase {

    /// The naming contract between the download script and `BundledCrests.filename`. Getting this
    /// wrong doesn't crash — every lookup just silently misses and every crest quietly goes back
    /// to the network, which is the exact regression this file exists to catch.
    func testFilenameMatchesTheStorageKeyShape() {
        XCTAssertEqual(BundledCrests.filename(sport: .nfl, abbr: "ARI", league: nil),
                       "crest-nfl---ari")
        XCTAssertEqual(BundledCrests.filename(sport: .soccer, abbr: "MCI", league: "England"),
                       "crest-soccer-england-mci")
        // Codes and leagues are lowercased and non-alphanumerics collapse, so a club with a space
        // or a dot in its league lands on a predictable name.
        XCTAssertEqual(BundledCrests.filename(sport: .soccer, abbr: "psg", league: "France 1"),
                       "crest-soccer-france-1-psg")
    }

    /// Spot-check across sports that the files are actually in the bundle and resolvable through
    /// the real entry point.
    func testWellKnownCrestsResolveFromTheBundle() {
        let cases: [(Sport, String, String?)] = [
            (.nfl, "ARI", nil), (.nfl, "KC", nil),
            (.nba, "LAL", nil), (.baseball, "NYY", nil),
        ]
        for (sport, abbr, league) in cases {
            XCTAssertNotNil(BundledCrests.url(sport: sport, abbr: abbr, league: league),
                            "\(sport.rawValue)/\(abbr) is not bundled")
        }
    }

    /// The whole point: a bundled crest must win over the network, and it must be a file URL so
    /// nothing downstream tries to resize it at an edge.
    func testTeamLogoURLPrefersTheBundledFile() throws {
        let url = try XCTUnwrap(Sport.nfl.teamLogoURL(forAbbr: "ARI"))
        XCTAssertTrue(url.isFileURL, "expected a bundled file, got \(url)")
        XCTAssertEqual(AppImagePipeline.transformed(url, pixels: 192), url,
                       "a file URL must never be rewritten into a render request")
    }

    /// An unknown club still resolves to *something* remote rather than nil, so a team we have no
    /// bundled crest for degrades to the network path instead of rendering nothing.
    func testUnbundledTeamFallsBackToTheNetwork() {
        XCTAssertNil(BundledCrests.url(sport: .nfl, abbr: "ZZZ"))
        let fallback = Sport.nfl.teamLogoURL(forAbbr: "ZZZ")
        XCTAssertEqual(fallback?.isFileURL, false)
    }

    /// Empty is not a lookup. Traded rows carry a deliberately blank `team_abbr`.
    func testBlankAbbrResolvesToNothing() {
        XCTAssertNil(BundledCrests.url(sport: .nfl, abbr: ""))
    }

    /// A bundled crest has to survive the whole pipeline, not just resolve to a path.
    ///
    /// It did not, at first: `ImageCache.fetch` guards on `response as? HTTPURLResponse`, and a
    /// `file://` load returns a plain `URLResponse`, so every bundled crest failed that check and
    /// fell back to the network — the bundling did nothing while looking like it worked. Only an
    /// end-to-end assertion catches that.
    func testBundledCrestActuallyDecodes() async throws {
        let url = try XCTUnwrap(Sport.nfl.teamLogoURL(forAbbr: "ARI"))
        let image = await ImageCache.shared.image(for: url, targetSize: CGSize(width: 40, height: 40))
        XCTAssertNotNil(image, "bundled crest at \(url.path) did not decode")
    }

    /// The bundle should hold the full set; a partial copy means a download run was interrupted
    /// and a chunk of clubs silently went back to the network.
    func testBundleHoldsTheWholeSet() throws {
        let urls = Bundle.main.urls(forResourcesWithExtension: "webp", subdirectory: nil) ?? []
        let crests = urls.filter { $0.lastPathComponent.hasPrefix("crest-") }
        XCTAssertGreaterThanOrEqual(crests.count, 300,
                                    "only \(crests.count) crests bundled, re-run the download")
    }
}
