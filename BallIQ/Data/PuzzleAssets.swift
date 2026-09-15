import SwiftUI

/// A puzzle's asset bundle: every remote image its board and result screen draw, each at the size
/// it is drawn at.
///
/// Built from puzzle content alone, so it can be computed anywhere a puzzle is known (Home's
/// dailies, a Browse row, onboarding's first board, a deep link) and warmed long before the player
/// taps (`prefetch`), then checked again at the moment they do (`PuzzleAssetGate`). The rule it
/// exists for: no headshot on a board ever paints a placeholder first (user directive 2026-09-14,
/// "we can't have ANY latency for headshots").
///
/// Each constructor mirrors its format's call sites (same URL resolution, same size) because a
/// warm under a different URL is a miss. A size only has to reach the drawn *bucket* or above:
/// `ImageCache` serves a larger decode to a smaller frame.
struct PuzzleAssets {
    struct Image: Equatable {
        let url: URL
        let size: CGSize
    }

    /// Cap on how long a cold open holds the board back. Long enough for a bundle on a normal
    /// connection; short enough that a dead CDN degrades to monograms rather than a stuck screen.
    static let startTimeout: TimeInterval = 2

    let images: [Image]

    init(images: [Image]) {
        var seen: Set<String> = []
        self.images = images.filter {
            seen.insert("\($0.url.absoluteString)|\(Int(AppImagePipeline.pixelBucket(for: $0.size)))").inserted
        }
    }

    /// Keep4/Cut4: the 8 board headshots at hero size (`Keep4CardView` draws up to 140 pt, and
    /// `Keep4ResultView` reuses the same photos at 48 pt) plus each card's crest, which the corner
    /// badge and the watermark both fetch at `crestWarmSize`.
    init(keep4: Keep4Puzzle) {
        let sport = keep4.sport
        let headshots = Self.images(keep4.players.map(\.headshot), size: AppImagePipeline.cardWarmSize)
        let crests = sport.hasTeams
            ? keep4.players.compactMap { sport.teamLogoURL(forAbbr: $0.teamAbbr) }
                .map { Image(url: $0, size: AppImagePipeline.crestWarmSize) }
            : []
        self.init(images: headshots + crests)
    }

    /// Journeyman: the career path's crests and the answer's reveal photo. `CareerPathTimeline`
    /// looks each crest up with the stint's league and draws none for a historical stint (the code
    /// names a different franchise today), so the bundle does the same.
    init(journeyman: JourneymanPuzzle) {
        let sport = journeyman.sport
        let crests = sport.hasTeams
            ? journeyman.stints
                .filter { !($0.historical ?? false) }
                .compactMap { sport.teamLogoURL(forAbbr: $0.teamAbbr, league: $0.league) }
                .map { Image(url: $0, size: AppImagePipeline.crestWarmSize) }
            : []
        self.init(images: crests + Self.images([journeyman.headshot], size: AppImagePipeline.warmSize))
    }

    /// Who Am I?: the board has no images, so the bundle is only the reveal photo, and only once
    /// the answer's catalog row has been resolved (`WhoAmIAnswerPhoto`).
    init(whoAmIAnswer row: CatalogSeason?) {
        self.init(images: Self.images([row?.headshot], size: AppImagePipeline.warmSize))
    }

    /// Empty strings are the catalog's "no photo" marker after the M26 rehost cleared every source
    /// that only ever served a placeholder, so they must not become URLs.
    private static func images(_ headshots: [String?], size: CGSize) -> [Image] {
        headshots.compactMap { raw in
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty,
                  let url = URL(string: raw) else { return nil }
            return Image(url: url, size: size)
        }
    }

    /// Whether every image is already decoded. Synchronous, so a gate can decide on its first frame.
    var isCached: Bool {
        images.allSatisfy {
            ImageCache.shared.cached($0.url, pixelSize: AppImagePipeline.pixelBucket(for: $0.size)) != nil
        }
    }

    /// Fire-and-forget warm at background priority. Safe to call on every appearance: cached and
    /// in-flight images are coalesced inside `ImageCache`.
    func prefetch() {
        let bySize = Dictionary(grouping: images) { AppImagePipeline.pixelBucket(for: $0.size) }
        for group in bySize.values {
            ImageCache.prefetch(group.map(\.url), targetSize: group[0].size)
        }
    }

    /// Waits until the whole bundle is decoded, or `timeout`. Returns whether everything landed.
    @discardableResult
    func prepare(timeout: TimeInterval = startTimeout) async -> Bool {
        await ImageCache.ensureCached(images.map { ($0.url, $0.size) }, timeout: timeout)
    }
}

/// Holds a puzzle screen back until its asset bundle is in memory, so the board's first frame
/// already has every photo.
///
/// On the normal path (warmed from Home, Browse or onboarding) `isCached` is already true in
/// `init` and the content renders on the very first frame, with no extra `.task` hop. Only a cold
/// open waits: a deep link, a duel, or a tap that beat the warm. That wait is capped at
/// `PuzzleAssets.startTimeout`. Wrapping the game view's whole body, rather than each entry point,
/// is what covers all of them: Home, Browse, Community, links, Versus, Blitz and onboarding all
/// construct the same game views.
struct PuzzleAssetGate<Content: View>: View {
    private let assets: PuzzleAssets
    private let content: () -> Content
    @State private var ready: Bool

    init(_ assets: PuzzleAssets, @ViewBuilder content: @escaping () -> Content) {
        self.assets = assets
        self.content = content
        _ready = State(initialValue: assets.isCached)
    }

    var body: some View {
        if ready {
            content()
        } else {
            ProgressView()
                .tint(Color.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
                .task {
                    await assets.prepare()
                    ready = true
                }
        }
    }
}
