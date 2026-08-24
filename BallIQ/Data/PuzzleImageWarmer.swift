import CoreGraphics
import Foundation

/// Warms the player photos a user is *about to* need, while they're still looking at something
/// else.
///
/// The problem this solves: a Keep4 daily is 8 player cards, and every one of those headshots
/// was previously fetched at the moment the card first rendered — so opening a daily meant
/// watching eight initials-monograms fill in one by one. Meanwhile the player had usually been
/// sitting on Home for several seconds doing nothing with the network, because Home draws no
/// headshots at all.
///
/// So: as soon as a sport's dailies land on Home, warm every headshot they contain. The vast
/// majority are never opened, which is fine — a warm entry costs one bounded background fetch
/// and the cache evicts under pressure on its own. What it buys is that the puzzles a player
/// *does* open are already decoded and render on the first frame (`RemoteImage.init`'s
/// synchronous cache probe).
///
/// Sizing: every headshot call site in the app draws at ≤48 pt, so all of them resolve to
/// `AppImagePipeline`'s 192 px bucket. One warm pass at `AppImagePipeline.warmSize` therefore
/// covers Keep4 cards, Over/Under, Draft & Spin, the WhoAmI reveal and the Journeyman reveal —
/// warming at any other size would fill a bucket nothing asks for (the exact waste the bucket
/// ladder exists to prevent).
enum PuzzleImageWarmer {

    /// Headshots carried directly by a Keep4 puzzle — its 8 player cards, the single biggest
    /// batch in the app and the one most likely to be opened from Home.
    static func warm(keep4: Keep4Puzzle?) {
        guard let keep4 else { return }
        warm(urls: keep4.players.compactMap(\.headshot))
    }

    /// The Journeyman answer's reveal photo. One URL, but it's the payoff frame of the format —
    /// a monogram there reads as a missing punchline.
    static func warm(journeyman: JourneymanPuzzle?) {
        guard let journeyman else { return }
        warm(urls: [journeyman.headshot].compactMap { $0 })
    }

    /// Every daily currently loaded on Home, across whichever sports have landed.
    ///
    /// WhoAmI is deliberately absent: its content model carries no photo URL and the answer's
    /// headshot is resolved from catalog rows at reveal time (`WhoAmIPuzzle.headshot(from:for:)`),
    /// so there is nothing to warm until the player has already finished the puzzle. Warming it
    /// would mean pre-fetching the answer, which is both wasted work and a spoiler surface.
    static func warmDailies(keep4: [Keep4Puzzle], journeyman: [JourneymanPuzzle]) {
        var urls = keep4.flatMap { $0.players.compactMap(\.headshot) }
        urls.append(contentsOf: journeyman.compactMap(\.headshot))
        warm(urls: urls)
    }

    /// Arbitrary already-resolved headshot strings (Draft & Spin rosters, ladder boards).
    static func warm(urls: [String]) {
        // Empty strings are the catalog's "no photo" marker after the M26 rehost cleared every
        // source that only ever served a placeholder — they must not become URLs.
        let resolved = urls
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap(URL.init(string:))
        guard !resolved.isEmpty else { return }
        ImageCache.prefetch(resolved, targetSize: AppImagePipeline.warmSize)
    }
}
