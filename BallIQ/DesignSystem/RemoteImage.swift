import SwiftUI
import ImageIO
import UIKit

/// Shared remote-image loading for every crest/headshot surface in the app, replacing the bare
/// `AsyncImage` that used to be copy-pasted at 11 call sites (AGENTS.md §4).
///
/// `AsyncImage` was measurably the wrong tool here, for three compounding reasons found while
/// diagnosing "logos are slow to load" (2026-07-27, see docs/grid-axes-research.md):
///
/// 1. It keeps **no decoded-image cache** across view identity changes. In a `LazyVGrid` or a
///    scrolling picker, every re-appearance is a fresh `URLCache` lookup plus a full PNG decode,
///    flashing blank→image each time even though nothing changed.
/// 2. It rides `URLSession.shared`, whose default `URLCache` is ~512 KB memory / ~10 MB disk on
///    iOS. The team-logo bucket is 363 objects / 22.5 MB — more than twice the disk budget — so
///    the working set could never fit and crests re-downloaded indefinitely. (`AppImagePipeline
///    .configureURLCache()` raises that; this cache sits in front of it.)
/// 3. It has no notion of "I am drawing this at 22 pt" — a 500 px, 62 KB-average source crest was
///    decoded at full size for a chip a tenth that big.
///
/// This type fixes all three: an `NSCache` of *decoded, already-downsampled* images keyed by
/// (url, pixel bucket), in-flight request coalescing so nine cells asking for the same crest
/// issue one request, and a synchronous cache hit in `init` so a warm image renders on the very
/// first frame instead of popping in a frame later.
struct RemoteImage<Placeholder: View, Failure: View>: View {
    private let url: URL?
    /// Point size the image is drawn at. Drives both server-side transform selection and local
    /// downsampling — pass the real rendered size, not a guess.
    private let targetSize: CGSize
    private let contentMode: ContentMode
    private let placeholder: () -> Placeholder
    private let failure: () -> Failure

    /// Seeded synchronously from the cache so an already-loaded crest never flashes a
    /// placeholder on re-appearance — the specific flicker `AsyncImage` caused in Grid's board.
    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?,
         targetSize: CGSize,
         contentMode: ContentMode = .fit,
         @ViewBuilder placeholder: @escaping () -> Placeholder,
         @ViewBuilder failure: @escaping () -> Failure) {
        self.url = url
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.failure = failure
        _image = State(initialValue: url.flatMap {
            ImageCache.shared.cached($0, pixelSize: AppImagePipeline.pixelBucket(for: targetSize))
        })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard image == nil, let url else { return }
        failed = false
        let loaded = await ImageCache.shared.image(for: url, targetSize: targetSize)
        if let loaded { image = loaded } else { failed = true }
    }
}

extension RemoteImage where Placeholder == Color, Failure == Color {
    /// The common case: nothing while loading, nothing on failure. Matches what most of the old
    /// `AsyncImage` call sites did (`else { Color.clear }`).
    init(url: URL?, targetSize: CGSize, contentMode: ContentMode = .fit) {
        self.init(url: url, targetSize: targetSize, contentMode: contentMode,
                  placeholder: { Color.clear }, failure: { Color.clear })
    }
}

extension RemoteImage where Placeholder == Color {
    /// Blank while loading, caller-supplied fallback on failure — the `TeamLogoBadge` shape,
    /// where a 404 (defunct franchise) must degrade to the abbreviation, never an empty disc.
    init(url: URL?, targetSize: CGSize, contentMode: ContentMode = .fit,
         @ViewBuilder failure: @escaping () -> Failure) {
        self.init(url: url, targetSize: targetSize, contentMode: contentMode,
                  placeholder: { Color.clear }, failure: failure)
    }
}

// MARK: - Cache

/// Decoded-image cache with in-flight coalescing. An `actor` so the in-flight table is safe
/// without a lock, but the *read* path (`cached`) is a nonisolated `NSCache` hit so a warm image
/// can be pulled synchronously during `View.init` — that synchronous hit is the whole point, and
/// an `await` there would reintroduce the one-frame pop it exists to remove.
actor ImageCache {
    static let shared = ImageCache()

    /// `NSCache` (not a dictionary) so the system can evict under memory pressure on its own.
    /// Cost is the decoded byte count, capped well under what 363 downsampled crests need so the
    /// full set stays resident in practice.
    private static let store: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 600
        return cache
    }()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private static func key(_ url: URL, pixelSize: CGFloat) -> NSString {
        "\(url.absoluteString)|\(Int(pixelSize))" as NSString
    }

    /// Synchronous cache probe — safe from any thread/actor (`NSCache` is thread-safe) and
    /// deliberately `nonisolated` so `RemoteImage.init` can seed its state without suspending.
    nonisolated func cached(_ url: URL, pixelSize: CGFloat) -> UIImage? {
        Self.store.object(forKey: Self.key(url, pixelSize: pixelSize))
    }

    func image(for url: URL, targetSize: CGSize) async -> UIImage? {
        let pixels = AppImagePipeline.pixelBucket(for: targetSize)
        let cacheKey = Self.key(url, pixelSize: pixels)
        if let hit = Self.store.object(forKey: cacheKey) { return hit }
        // Coalesce: Grid's board asks for the same three crests from multiple slots in the same
        // frame, and the pickers ask for dozens at once. Without this each duplicate is its own
        // request, which is exactly the traffic the cache is meant to remove.
        if let existing = inFlight[cacheKey as String] { return await existing.value }

        let task = Task<UIImage?, Never> {
            let transformed = AppImagePipeline.transformed(url, pixels: pixels)
            var data = try? await Self.fetch(transformed)
            // The render endpoint is a paid Supabase feature and can 400 on an unsupported
            // source. Retry the plain object URL rather than dropping the crest — but only when
            // `transformed` actually rewrote something, or this is the same request twice.
            if data == nil, transformed != url {
                data = try? await Self.fetch(url)
            }
            guard let data else { return nil }
            return AppImagePipeline.downsample(data, to: pixels)
        }
        inFlight[cacheKey as String] = task
        let image = await task.value
        inFlight[cacheKey as String] = nil
        if let image {
            Self.store.setObject(image, forKey: cacheKey, cost: image.byteCost)
        }
        return image
    }

    // MARK: - Prefetch

    /// Keys already queued for warming, so a repeated prefetch of the same screen's images
    /// doesn't re-enqueue work already in flight or already failed. Bounded — a warm pass over
    /// every daily in every sport is a few hundred entries, and this drops the whole set rather
    /// than growing without limit on a very long session.
    private var warmed: Set<String> = []

    /// Warm images into the cache *before* anything asks to draw them.
    ///
    /// Fire-and-forget: returns immediately, does its work at `.utility` so it can never
    /// outrank a fetch for something actually on screen. Safe to call repeatedly — anything
    /// already cached, already warmed, or already in flight is skipped.
    nonisolated static func prefetch(_ urls: [URL], targetSize: CGSize) {
        guard !urls.isEmpty else { return }
        Task(priority: .utility) { await shared.warm(urls, targetSize: targetSize) }
    }

    /// Bounded to `maxConcurrent` in-flight fetches. The cap is the point: a Keep4 daily is 8
    /// headshots and warming every sport's dailies at once is ~100 URLs, which unbounded would
    /// saturate the connection the visible screen is still using.
    private func warm(_ urls: [URL], targetSize: CGSize, maxConcurrent: Int = 3) async {
        let pixels = AppImagePipeline.pixelBucket(for: targetSize)
        if warmed.count > 2_000 { warmed.removeAll(keepingCapacity: true) }

        var queue: [URL] = []
        for url in urls {
            let key = Self.key(url, pixelSize: pixels)
            if Self.store.object(forKey: key) != nil { continue }   // already decoded
            let string = key as String
            if warmed.contains(string) { continue }
            warmed.insert(string)
            queue.append(url)
        }
        guard !queue.isEmpty else { return }

        var next = queue.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(maxConcurrent, queue.count) {
                guard let url = next.next() else { break }
                group.addTask { _ = await self.image(for: url, targetSize: targetSize) }
            }
            while await group.next() != nil {
                guard let url = next.next() else { continue }
                group.addTask { _ = await self.image(for: url, targetSize: targetSize) }
            }
        }
    }

    /// Returns nil (rather than throwing) on a non-2xx so the caller can fall back to the
    /// untransformed URL — the Supabase render endpoint is a paid feature and a project without
    /// it enabled must still get its logos, just unresized.
    /// Every image request asks for WebP.
    ///
    /// `URLSession` sends `Accept: */*` by default, and both CDNs in front of us content-negotiate
    /// on that header: Supabase's render endpoint returns PNG unless WebP is requested, and
    /// Cloudinary's `f_auto` means "whatever the client says it takes". So the default cost us
    /// roughly 6x on every single image — measured on one 192px crest, 36,915 bytes as PNG against
    /// 5,958 as WebP. ImageIO has decoded WebP since iOS 14, and `downsample` goes through
    /// `CGImageSource`, so nothing downstream needs to know.
    private static let acceptHeader = "image/webp,image/avif,image/*;q=0.8,*/*;q=0.5"

    private static func fetch(_ url: URL) async throws -> Data? {
        // Bundled assets (`BundledCrests`) come through here as `file://`, and a file response is
        // a plain `URLResponse` — the HTTP status guard below rejects it, which silently failed
        // *every* bundled crest and sent them all back to the network. Read those directly.
        if url.isFileURL { return try? Data(contentsOf: url) }
        var request = URLRequest(url: url)
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }
}

private extension UIImage {
    /// Decoded size in bytes, for `NSCache` cost accounting.
    var byteCost: Int {
        guard let cg = cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

// MARK: - Pipeline policy

/// URL-transform + downsampling policy, factored out of the cache so it's independently testable
/// and so `configureURLCache()` has an obvious home to be called from at launch.
enum AppImagePipeline {
    /// Screen scale, captured once at launch. `pixelBucket` runs inside `ImageCache`'s actor as
    /// well as on the main thread, and `UITraitCollection.current` is only meaningful on the
    /// main actor — reading it from the actor would be a data race for a value that never
    /// changes on a phone. Defaults to 3 (the densest common scale) so a pre-`configure()` call
    /// over-fetches slightly rather than shipping a blurry crest.
    nonisolated(unsafe) private(set) static var screenScale: CGFloat = 3

    /// Call once at launch, on the main actor, before any `URLSession.shared` use.
    ///
    /// Raises `URLSession.shared`'s cache off the iOS default (~512 KB memory / ~10 MB disk),
    /// which could not hold the 22.5 MB team-logo bucket and therefore thrashed — crests
    /// re-downloaded indefinitely because the working set never fit. Storage serves these
    /// objects `public, max-age=31536000, immutable`, so a generous disk budget means a crest is
    /// fetched once per install rather than once per screen.
    @MainActor static func configure() {
        screenScale = UITraitCollection.current.displayScale > 0
            ? UITraitCollection.current.displayScale : 3
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
    }

    /// Rendition sizes we're willing to ask for, in pixels. Bucketed rather than exact so the CDN
    /// (and our own cache) sees a handful of stable URLs instead of one per call site's point
    /// size — a cache keyed on "97 px" that never gets asked for 97 px again is worthless.
    ///
    /// The ladder is deliberately coarse, and sized against what this app actually draws rather
    /// than round numbers. Every crest/headshot call site falls between 14 pt and 52 pt except a
    /// single 84 pt avatar — so **192 px covers every one of them but that outlier** at 3x, and
    /// 384 px covers the outlier. Two rungs means a given crest is fetched and cached once,
    /// app-wide.
    ///
    /// Both finer ladders tried first were worse, each caught by a failing test rather than by
    /// inspection: [64, 128, 256, 512] split the small chips (18 pt → 64 px, 22 pt → 128 px), and
    /// [128, 256, 512] split the badges (40 pt → 128 px, 44 pt → 256 px). In both cases the same
    /// crest was downloaded twice — the exact waste bucketing exists to prevent. Sizes cluster
    /// where the design puts them, not on powers of two, so the rungs have to be chosen to
    /// straddle the clusters rather than land inside them.
    static let buckets: [CGFloat] = [192, 384]

    /// The size `PuzzleImageWarmer` prefetches at. Every headshot call site in the app draws at
    /// ≤48 pt, so this resolves to the 192 px bucket and one warm pass covers all of them —
    /// warming at a size that landed in a different bucket would fill a cache entry no view
    /// ever asks for.
    static let warmSize = CGSize(width: 48, height: 48)

    /// The size the Keep4 *board* card draws a headshot at, which since the 2026-08-27 redesign
    /// is up to 150 pt — the 384 px bucket, not `warmSize`'s 192. Warming that card at
    /// `warmSize` therefore filled an entry it never asks for, and the hero photo on all 8 cards
    /// went back to fetching on first render. Headshots come from CDNs with no transform
    /// endpoint, so both buckets are the same URL and the second one is served by `URLCache` —
    /// which is why the compact 48 pt result card still renders promptly off this warm.
    static let cardWarmSize = CGSize(width: 150, height: 150)

    /// The size every crest is fetched at (`TeamLogoBadge`'s default, and what the Keep4
    /// watermark pins itself to via `fetchSize`). One bucket for all crest call sites is the
    /// whole point — a second one would double both the traffic and the warm set.
    static let crestWarmSize = CGSize(width: 40, height: 40)

    /// Smallest bucket that covers `size` at native screen scale.
    static func pixelBucket(for size: CGSize) -> CGFloat {
        let needed = max(size.width, size.height) * screenScale
        return buckets.first { $0 >= needed } ?? buckets[buckets.count - 1]
    }

    /// Rewrites a Supabase Storage public-object URL to the image-transform endpoint at `pixels`.
    ///
    /// Verified live on this project 2026-07-27: `object/public/team-logos/nfl/_/kc.png` is
    /// 40,228 bytes, while the same asset through `render/image/public/...?width=96&height=96`
    /// is 8,578 bytes — 4.7x smaller, same `cache-control: public, max-age=31536000, immutable`.
    /// Across the bucket that takes the working set from 22.5 MB to roughly 5 MB.
    ///
    /// Non-Storage URLs (ESPN CDN crests, nflverse headshots) are returned unchanged — there is
    /// no transform endpoint for those, and they still benefit from downsampling + caching.
    static func transformed(_ url: URL, pixels: CGFloat) -> URL {
        if let storage = supabaseRender(url, pixels: pixels) { return storage }
        if let cloudinary = cloudinaryResized(url, pixels: pixels) { return cloudinary }
        if let espn = espnHeadshotResized(url, pixels: pixels) { return espn }
        return url
    }

    /// ESPN's `a.espncdn.com` headshot archive (`espn_nfl_backfill`/`espn_search_backfill`'s
    /// source, and every un-rehosted row those wrote before a `--repoint` ran) is one of the
    /// biggest still-external asset classes in the catalog. It has no public transform docs, but
    /// its own site pages images through an undocumented "combiner" endpoint that does take a
    /// size — verified live 2026-09-02: one NFL headshot went from 230,577 bytes at full res to
    /// 35,652 through `/combiner/i?img=<path>&w=192&h=192`, a 6.5x cut, same trick as the
    /// Cloudinary rewrite above for the league CDNs.
    ///
    /// Scoped to `/i/headshots/` specifically — `testLeavesHostsWithoutATransformAPIUnchanged`
    /// pins `/i/teamlogos/` as untransformed, and this rewrite hasn't been verified against that
    /// path, so it only touches the shape it was measured against.
    private static func espnHeadshotResized(_ url: URL, pixels: CGFloat) -> URL? {
        guard url.host == "a.espncdn.com", url.path.hasPrefix("/i/headshots/") else { return nil }
        var comps = URLComponents()
        comps.scheme = url.scheme
        comps.host = url.host
        comps.path = "/combiner/i"
        let size = String(Int(pixels))
        comps.queryItems = [
            URLQueryItem(name: "img", value: url.path),
            URLQueryItem(name: "w", value: size),
            URLQueryItem(name: "h", value: size),
        ]
        return comps.url
    }

    private static func supabaseRender(_ url: URL, pixels: CGFloat) -> URL? {
        let marker = "/storage/v1/object/public/"
        let absolute = url.absoluteString
        guard let range = absolute.range(of: marker) else { return nil }
        let base = absolute[absolute.startIndex..<range.lowerBound]
        let objectPath = absolute[range.upperBound...]
        let size = Int(pixels)
        let rewritten = "\(base)/storage/v1/render/image/public/\(objectPath)"
            + "?width=\(size)&height=\(size)&resize=contain&quality=80"
        return URL(string: rewritten)
    }

    /// Constrain a Cloudinary-hosted source to the size we actually draw.
    ///
    /// The league CDNs (`static.www.nfl.com`, `img.mlbstatic.com`) are Cloudinary, and their URLs
    /// carry a transformation segment right after `/image/upload/`. Ours mostly said `f_auto,q_auto`
    /// — format and quality, **no width** — so the request returned the full-resolution master and
    /// the phone downsampled it locally. Measured on one NFL headshot: 4.2 MB as PNG, 742 KB once
    /// `Accept: image/webp` was sent, and 6.9 KB with `w_192` added. Those are not rehosted assets
    /// and there is no transform endpoint of ours in front of them, so this is the only lever —
    /// and it is a 100x one.
    ///
    /// A URL that already names a width is left alone: `img.mlbstatic.com` ships `w_213`, which is
    /// already the right order of magnitude (6 KB), and overriding a curated transform is how you
    /// break someone's carefully-chosen crop.
    /// Cloudinary serves the same transform grammar under both delivery types, and the league
    /// CDNs use different ones: `img.mlbstatic.com` is `/image/upload/`, `static.www.nfl.com` is
    /// `/image/private/`. Matching only the first is why the NFL headshots stayed at 168 KB after
    /// the WebP change landed — the rewrite silently did nothing for them.
    private static let cloudinaryMarkers = ["/image/upload/", "/image/private/"]

    private static func cloudinaryResized(_ url: URL, pixels: CGFloat) -> URL? {
        let absolute = url.absoluteString
        guard let marker = cloudinaryMarkers.first(where: { absolute.contains($0) }),
              let range = absolute.range(of: marker) else { return nil }
        let tail = absolute[range.upperBound...]
        guard let slash = tail.firstIndex(of: "/") else { return nil }
        let firstSegment = String(tail[tail.startIndex..<slash])
        let size = Int(pixels)

        // Cloudinary's transformation segment is comma-separated `key_value` pairs. Anything else
        // (a version like `v1`, or the asset id itself) means this URL carries no transforms, so
        // a new segment is inserted instead of edited.
        let isTransformSegment = firstSegment.contains("_")
            && firstSegment.split(separator: ",").allSatisfy { $0.contains("_") }
        guard isTransformSegment else {
            let rewritten = absolute.replacingOccurrences(
                of: marker, with: "\(marker)w_\(size),c_limit/", options: [], range: range)
            return URL(string: rewritten)
        }
        guard !firstSegment.split(separator: ",").contains(where: { $0.hasPrefix("w_") }) else {
            return nil
        }
        let rewrittenSegment = "\(firstSegment),w_\(size),c_limit"
        let start = absolute.index(range.upperBound, offsetBy: 0)
        let end = absolute.index(start, offsetBy: firstSegment.count)
        var out = absolute
        out.replaceSubrange(start..<end, with: rewrittenSegment)
        return URL(string: out)
    }

    /// Decodes straight to `maxPixels` via ImageIO rather than decoding full-size and scaling —
    /// keeps a 500 px source crest from ever occupying full-resolution memory for a 22 pt chip,
    /// and matters most for headshots, which have no server-side transform available.
    static func downsample(_ data: Data, to maxPixels: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: thumb)
    }
}
