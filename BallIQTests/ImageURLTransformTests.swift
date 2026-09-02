import XCTest
@testable import BallIQ

/// Pins `AppImagePipeline.transformed`, which is where an image request stops being
/// "full-resolution master" and becomes "the size we actually draw".
///
/// Measured 2026-08-28, one NFL headshot, the three states this file is about:
///
///   Accept: * / *,       no width  -> 4,170,398 bytes (PNG)
///   Accept: image/webp,  no width  ->   742,198 bytes (WebP)
///   Accept: image/webp,  w_192     ->     6,906 bytes (WebP)
///
/// A single K4C4 board was downloading 3.9 MB of images before this. The rules below are cheap
/// to break by accident — a `w_` that lands in the wrong path segment silently 404s, and a
/// missing one silently costs 100x — so they are pinned rather than trusted.
final class ImageURLTransformTests: XCTestCase {

    // MARK: - Supabase Storage

    func testStorageObjectBecomesARenderRequest() throws {
        let url = try XCTUnwrap(URL(string:
            "https://x.supabase.co/storage/v1/object/public/player-headshots/nfl/abc.png"))
        let out = AppImagePipeline.transformed(url, pixels: 192).absoluteString
        XCTAssertTrue(out.contains("/storage/v1/render/image/public/"), out)
        XCTAssertTrue(out.contains("width=192"), out)
        XCTAssertTrue(out.contains("height=192"), out)
    }

    // MARK: - Cloudinary (the league CDNs)

    /// The case that was costing 100x: transforms present, but no width.
    func testCloudinaryTransformSegmentGainsAWidth() throws {
        let url = try XCTUnwrap(URL(string:
            "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/abc123"))
        let out = AppImagePipeline.transformed(url, pixels: 192).absoluteString
        XCTAssertEqual(out, "https://static.www.nfl.com/image/upload/f_auto,q_auto,w_192,c_limit/league/abc123")
    }

    /// The NFL CDN uses Cloudinary's *private* delivery type. Matching only `/image/upload/`
    /// left every NFL headshot at 168 KB after the WebP change — the rewrite quietly no-op'd,
    /// which is the failure mode this whole file exists to prevent.
    func testCloudinaryPrivateDeliveryIsAlsoResized() throws {
        let url = try XCTUnwrap(URL(string:
            "https://static.www.nfl.com/image/private/f_auto,q_auto/league/bo2zhv6axwvce6mb0g5l"))
        let out = AppImagePipeline.transformed(url, pixels: 192).absoluteString
        XCTAssertEqual(out, "https://static.www.nfl.com/image/private/f_auto,q_auto,w_192,c_limit/league/bo2zhv6axwvce6mb0g5l")
    }

    /// A curated width is left alone — `img.mlbstatic.com` ships `w_213`, already ~6 KB, and
    /// overriding someone's chosen crop is a different kind of bug.
    func testCloudinaryWidthIsNotOverridden() throws {
        let raw = "https://img.mlbstatic.com/mlb-photos/image/upload/"
            + "w_213,d_people:generic:headshot:silo:current.png,q_auto:best,f_auto/v1/people/110005/headshot/67/current"
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(AppImagePipeline.transformed(url, pixels: 192).absoluteString, raw)
    }

    /// No transformation segment at all — a width segment is inserted rather than mangling the
    /// version or the asset id, which would 404.
    func testCloudinaryWithoutTransformsGetsAnInsertedSegment() throws {
        let url = try XCTUnwrap(URL(string:
            "https://static.www.nfl.com/image/upload/v1/league/abc123"))
        let out = AppImagePipeline.transformed(url, pixels: 384).absoluteString
        XCTAssertEqual(out, "https://static.www.nfl.com/image/upload/w_384,c_limit/v1/league/abc123")
    }

    /// The requested bucket is what lands in the URL, both of them.
    func testWidthTracksTheRequestedBucket() throws {
        let url = try XCTUnwrap(URL(string:
            "https://static.www.nfl.com/image/upload/f_auto/league/abc123"))
        for pixels in AppImagePipeline.buckets {
            XCTAssertTrue(
                AppImagePipeline.transformed(url, pixels: pixels).absoluteString
                    .contains("w_\(Int(pixels)),"),
                "bucket \(pixels) missing from the rewritten URL")
        }
    }

    // MARK: - ESPN headshot combiner

    /// Verified live 2026-09-02: 230,577 bytes full-res -> 35,652 through the combiner, a 6.5x
    /// cut on one of the largest remaining still-external asset classes in the catalog.
    func testEspnHeadshotGetsRewrittenToTheCombiner() throws {
        let url = try XCTUnwrap(URL(string:
            "https://a.espncdn.com/i/headshots/nfl/players/full/3139477.png"))
        let out = AppImagePipeline.transformed(url, pixels: 192).absoluteString
        XCTAssertTrue(out.hasPrefix("https://a.espncdn.com/combiner/i?"), out)
        XCTAssertTrue(out.contains("img=/i/headshots/nfl/players/full/3139477.png"), out)
        XCTAssertTrue(out.contains("w=192"), out)
        XCTAssertTrue(out.contains("h=192"), out)
    }

    /// The requested bucket tracks the combiner's `w`/`h`, both of them.
    func testEspnHeadshotWidthTracksTheRequestedBucket() throws {
        let url = try XCTUnwrap(URL(string:
            "https://a.espncdn.com/i/headshots/nba/players/full/1966.png"))
        for pixels in AppImagePipeline.buckets {
            let out = AppImagePipeline.transformed(url, pixels: pixels).absoluteString
            XCTAssertTrue(out.contains("w=\(Int(pixels))"), "bucket \(pixels) missing: \(out)")
        }
    }

    /// ESPN's team-logo path (`/i/teamlogos/`) is a different shape this rewrite hasn't been
    /// verified against — `AppImagePipelineTests.testLeavesHostsWithoutATransformAPIUnchanged`
    /// pins it untouched, and this test locks the same boundary from the other file.
    func testEspnTeamLogoPathIsNotRewritten() throws {
        let raw = "https://a.espncdn.com/i/teamlogos/nfl/500/kc.png"
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(AppImagePipeline.transformed(url, pixels: 192).absoluteString, raw)
    }

    // MARK: - Everything else

    /// Wikimedia hosts ~24k of our headshots and has no transform API. It must come back
    /// untouched rather than gaining query junk that could break the request.
    func testUnknownHostsAreUntouched() throws {
        let raw = "https://upload.wikimedia.org/wikipedia/commons/1/11/Clint_Didier_2010.jpg"
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(AppImagePipeline.transformed(url, pixels: 192).absoluteString, raw)
    }

    /// A bundled crest is a `file://` URL (see `Sport.teamLogoURL`) and must never be rewritten
    /// into a network request.
    func testFileURLsAreUntouched() throws {
        let url = URL(fileURLWithPath: "/tmp/crest-nfl-ari.webp")
        XCTAssertEqual(AppImagePipeline.transformed(url, pixels: 192), url)
    }
}
