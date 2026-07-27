import XCTest
@testable import BallIQ

/// Locks the crest/headshot loading policy introduced with `RemoteImage` (2026-07-27), which
/// replaced bare `AsyncImage` after measuring why "logos are slow to load":
/// the team-logo bucket is 363 objects / 22.5 MB against an iOS default `URLCache` of ~10 MB,
/// with 62 KB-average 500 px sources drawn at 22 pt. Both halves of the fix — asking the CDN for
/// a small rendition, and bucketing so those renditions are actually cacheable — are pure
/// functions, so they're pinned here rather than left to a visual check.
final class AppImagePipelineTests: XCTestCase {

    // MARK: - Supabase Storage transform rewriting

    func testRewritesStoragePublicObjectURLToRenderEndpoint() {
        let url = URL(string: "https://nhccgufqwndtoasdbkhc.supabase.co"
                      + "/storage/v1/object/public/team-logos/nfl/_/kc.png")!
        let out = AppImagePipeline.transformed(url, pixels: 96)
        let s = out.absoluteString
        XCTAssertTrue(s.hasPrefix("https://nhccgufqwndtoasdbkhc.supabase.co"
                                  + "/storage/v1/render/image/public/team-logos/nfl/_/kc.png?"), s)
        XCTAssertTrue(s.contains("width=96"), s)
        XCTAssertTrue(s.contains("height=96"), s)
        XCTAssertTrue(s.contains("resize=contain"), s)
    }

    /// Object path is preserved verbatim — league-qualified keys (`soccer/england/liv.png`) must
    /// survive the rewrite or the crest 404s and the club renders bare.
    func testPreservesNestedObjectPath() {
        let url = URL(string: "https://x.supabase.co"
                      + "/storage/v1/object/public/team-logos/soccer/england/liv.png")!
        XCTAssertTrue(AppImagePipeline.transformed(url, pixels: 128).absoluteString
            .contains("/render/image/public/team-logos/soccer/england/liv.png?"))
    }

    /// ESPN CDN crests and nflverse headshots have no transform endpoint; rewriting them would
    /// produce a dead URL. They still get downsampled and cached, just not resized server-side.
    func testLeavesNonStorageURLsUnchanged() {
        for raw in ["https://a.espncdn.com/i/teamlogos/nfl/500/kc.png",
                    "https://static.www.nfl.com/image/private/headshot/player.png"] {
            let url = URL(string: raw)!
            XCTAssertEqual(AppImagePipeline.transformed(url, pixels: 96), url)
        }
    }

    /// A signed/private Storage URL is not the public-object shape, so it must not be rewritten
    /// into a public render path.
    func testLeavesNonPublicStorageURLUnchanged() {
        let url = URL(string: "https://x.supabase.co/storage/v1/object/sign/team-logos/a.png")!
        XCTAssertEqual(AppImagePipeline.transformed(url, pixels: 96), url)
    }

    // MARK: - Pixel bucketing

    /// Buckets exist so the CDN and our own cache see a handful of stable URLs. A cache keyed on
    /// "97 px" that nothing ever asks for again is worthless, so the bucket must be one of the
    /// declared sizes and must never be smaller than what the screen needs.
    func testBucketIsAlwaysADeclaredSizeAndCoversTheRequest() {
        let scale = AppImagePipeline.screenScale
        for points in [18, 22, 24, 40, 44, 48, 64, 120] {
            let size = CGSize(width: CGFloat(points), height: CGFloat(points))
            let bucket = AppImagePipeline.pixelBucket(for: size)
            XCTAssertTrue(AppImagePipeline.buckets.contains(bucket),
                          "\(points)pt → \(bucket)px is not a declared bucket")
            if bucket != AppImagePipeline.buckets.last {
                XCTAssertGreaterThanOrEqual(bucket, CGFloat(points) * scale,
                                            "\(points)pt bucket would render blurry")
            }
        }
    }

    /// Every crest/badge size the app actually draws at, from the 14 pt inline chip to the 52 pt
    /// badge. All of them must collapse to ONE rendition, or the same crest gets downloaded and
    /// cached more than once — the exact waste bucketing exists to prevent.
    ///
    /// This assertion has already rejected two ladders: [64, 128, 256, 512] split 18 pt from
    /// 22 pt, and [128, 256, 512] split 40 pt from 44 pt. Sizes cluster where the design puts
    /// them, not on powers of two. If a new call site draws a crest at a size that breaks this,
    /// move a rung — don't weaken the test.
    func testEveryCrestSizeInUseSharesOneBucket() {
        let inUse: [CGFloat] = [14, 18, 22, 24, 26, 28, 32, 36, 40, 44, 48, 52]
        let buckets = Set(inUse.map {
            AppImagePipeline.pixelBucket(for: CGSize(width: $0, height: $0))
        })
        XCTAssertEqual(buckets.count, 1,
                       "crest sizes \(inUse) should collapse to one rendition, got \(buckets)")
    }

    /// The one outlier — an 84 pt avatar — legitimately needs a bigger rendition than a 22 pt
    /// chip. It's the only reason a second rung exists.
    func testLargeAvatarGetsItsOwnLargerBucket() {
        let chip = AppImagePipeline.pixelBucket(for: CGSize(width: 22, height: 22))
        let avatar = AppImagePipeline.pixelBucket(for: CGSize(width: 84, height: 84))
        XCTAssertGreaterThan(avatar, chip)
    }

    func testOversizedRequestClampsToLargestBucketRatherThanFailing() {
        let huge = CGSize(width: 4000, height: 4000)
        XCTAssertEqual(AppImagePipeline.pixelBucket(for: huge), AppImagePipeline.buckets.last)
    }

    /// A non-square target is driven by its larger edge, so the rendition never under-covers.
    func testBucketUsesLargerEdge() {
        XCTAssertEqual(AppImagePipeline.pixelBucket(for: CGSize(width: 8, height: 48)),
                       AppImagePipeline.pixelBucket(for: CGSize(width: 48, height: 48)))
    }
}
