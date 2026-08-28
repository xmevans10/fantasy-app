import Foundation

/// Club and national crests shipped inside the app.
///
/// Crests are the one image set worth bundling. There are 311 of them, they change roughly never
/// (a rebrand, a promotion), and at least one appears on essentially every board in every format —
/// so they are the highest-hit, lowest-churn assets we have. At 96px WebP the whole set is 1.8 MB,
/// which is a rounding error against an install and buys a crest that is on screen in the first
/// frame, offline, forever.
///
/// Headshots are deliberately **not** bundled, and the arithmetic is why: 41,236 distinct photos
/// come to ~250 MB at 192px or ~125 MB at 96px, which is past the App Store's cellular-download
/// limit and a real cost to install conversion — and because the catalog keeps growing, a bundled
/// set would still need the network path for every player added after the build shipped. It would
/// buy a lower cache-miss rate for a permanent install-size cost. Crests are the opposite trade.
///
/// Returning a `file://` URL rather than an `Image` is what keeps this a one-line change at the
/// call site: `RemoteImage`, `ImageCache` and `PuzzleImageWarmer` all take URLs and treat this
/// like any other source, and `AppImagePipeline.transformed` leaves non-HTTP URLs alone.
enum BundledCrests {

    /// Marks a URL as one of our own rehosted Storage objects — i.e. the same pipeline that
    /// produced these files. `Sport.teamLogoURL` uses it to decide when a *fetched* crest should
    /// outrank the bundle: a Storage URL is the ordinary case and the bundle serves it faster,
    /// while anything else is a deliberate override and wins.
    static let storageMarker = "/storage/v1/object/public/"

    /// The bundle is a snapshot, and the `teams` table is live. A club that rebrands is therefore
    /// stale here until the next release: re-run the crest download (see
    /// `docs/BALLIQ_SPEC.md` and `tools/ingest/warm_cdn.py`'s sibling note) as part of cutting a
    /// build. That is the accepted cost — crest changes are rare and a release ships anyway,
    /// while the fetch it replaces happened on every board.

    /// Mirrors `tools/ingest/logos.py`'s storage key: sport, then the club's league (`_` for the
    /// single-competition US sports), then the team code — the same triple `teams` is keyed on,
    /// because a bare code is not unique across countries ("BRO" is Blackburn Rovers *and*
    /// Brisbane Roar).
    static func filename(sport: Sport, abbr: String, league: String?) -> String {
        let league = (league?.isEmpty == false) ? league! : "_"
        return "crest-\(slug(sport.rawValue))-\(slug(league))-\(slug(abbr))"
    }

    /// Non-alphanumerics collapse to `-`, matching the download script that produced the files.
    private static func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Cached because this is called for every crest on every board render, and a bundle lookup
    /// is a filesystem hit. `nil` is cached too — a miss is the common case for a club we have no
    /// crest for, and re-probing the bundle for it on every frame is the waste worth avoiding.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: URL?] = [:]

    static func url(sport: Sport, abbr: String, league: String? = nil) -> URL? {
        guard !abbr.isEmpty else { return nil }
        let name = filename(sport: sport, abbr: abbr, league: league)
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        // League-qualified first, then the unqualified form: soccer rows carry a country, but a
        // caller that only has the code (a Grid axis, a card) passes nil, and that must still
        // find the file for the US sports whose league is ''.
        let resolved = Bundle.main.url(forResource: name, withExtension: "webp")
            ?? Bundle.main.url(forResource: filename(sport: sport, abbr: abbr, league: nil),
                               withExtension: "webp")
        cache[name] = resolved
        return resolved
    }
}
