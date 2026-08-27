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
/// Sizing: a warm only counts if it lands in the same `AppImagePipeline` bucket the view will
/// ask for — the cache key is `url|pixels`, so a warm at the wrong size is worse than none (it
/// spends the bytes and still misses). Most call sites draw at ≤48 pt and resolve to the 192 px
/// bucket, which is what `warmSize` targets. The Keep4 *board* card is the exception since its
/// 2026-08-27 redesign: it draws the headshot at up to 150 pt, i.e. the 384 px bucket, so that
/// one warms at `cardWarmSize` instead.
///
/// Crests are warmed too, and were not before. They became a hero element on that same card (a
/// 168 pt watermark), where an unwarmed crest is a 43 KB fetch that lands about a second after
/// the card is already on screen — reported as "it feels totally disjointed". Every crest call
/// site in the app fetches at `crestWarmSize`, the watermark included (it pins its fetch size),
/// so a single warm entry serves all of them.
enum PuzzleImageWarmer {

    /// Headshots and team crests carried by a Keep4 puzzle — its 8 player cards, the single
    /// biggest batch in the app and the one most likely to be opened from Home.
    static func warm(keep4: Keep4Puzzle?) {
        guard let keep4 else { return }
        warm(urls: keep4.players.compactMap(\.headshot), targetSize: AppImagePipeline.cardWarmSize)
        warmCrests(sport: keep4.sport, abbrs: keep4.players.map(\.teamAbbr))
    }

    /// Team crests for `abbrs`, deduplicated — a puzzle's 8 cards routinely share franchises,
    /// and `ImageCache.warm` dedupes by cache key anyway, but not building the duplicates keeps
    /// the queue honest.
    static func warmCrests(sport: Sport, abbrs: [String]) {
        let urls = Set(abbrs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .compactMap { sport.teamLogoURL(forAbbr: $0) }
        guard !urls.isEmpty else { return }
        ImageCache.prefetch(urls, targetSize: AppImagePipeline.crestWarmSize)
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
        for puzzle in keep4 { warm(keep4: puzzle) }
        warm(urls: journeyman.compactMap(\.headshot))
    }

    /// Arbitrary already-resolved headshot strings (Draft & Spin rosters, ladder boards).
    static func warm(urls: [String], targetSize: CGSize = AppImagePipeline.warmSize) {
        // Empty strings are the catalog's "no photo" marker after the M26 rehost cleared every
        // source that only ever served a placeholder — they must not become URLs.
        let resolved = urls
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap(URL.init(string:))
        guard !resolved.isEmpty else { return }
        ImageCache.prefetch(resolved, targetSize: targetSize)
    }
}
