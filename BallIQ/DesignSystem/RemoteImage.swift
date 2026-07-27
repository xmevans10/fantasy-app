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

    /// Returns nil (rather than throwing) on a non-2xx so the caller can fall back to the
    /// untransformed URL — the Supabase render endpoint is a paid feature and a project without
    /// it enabled must still get its logos, just unresized.
    private static func fetch(_ url: URL) async throws -> Data? {
        let (data, response) = try await URLSession.shared.data(from: url)
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
        let marker = "/storage/v1/object/public/"
        let absolute = url.absoluteString
        guard let range = absolute.range(of: marker) else { return url }
        let base = absolute[absolute.startIndex..<range.lowerBound]
        let objectPath = absolute[range.upperBound...]
        let size = Int(pixels)
        let rewritten = "\(base)/storage/v1/render/image/public/\(objectPath)"
            + "?width=\(size)&height=\(size)&resize=contain&quality=80"
        return URL(string: rewritten) ?? url
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
