import Foundation

/// The one template every shared message is built from.
///
/// It exists because the alternative was six surfaces each assembling their own string: the Grid
/// already had a bespoke one, Keep 4 and Draft & Spin sent a bare PNG with no link at all, and
/// the two puzzle-invite sheets sent a raw `balliq://` URL. Nothing was consistent, so nothing
/// was recognisable, and only one of the six was even shaped like something a stranger could act
/// on. (AGENTS.md §4 — one shared table, not N per-case copies.)
///
/// The shape is Wordle's, which Immaculate Grid then borrowed, and it is not arbitrary:
///
///   1. **headline** — what happened, in words, with the sport and the number in it. This is the
///      only line guaranteed to survive a chat client's preview truncation, so it carries the
///      whole pitch on its own.
///   2. **board** — the spoiler-free picture (🟩⬛). Optional; it's what makes the message worth
///      looking at, but it means nothing without the line above it.
///   3. **detail** — score/streak, the bit that starts arguments.
///   4. **link** — always last, always an App Store URL, always campaign-tagged.
enum ShareMessage {
    /// The live App Store listing.
    static let appStoreID = "6785275045"

    /// App Analytics campaign token. Keep these low-cardinality and stable — they're the only
    /// install-attribution signal this loop has, and one campaign per board per day would shard
    /// the report into noise.
    ///
    /// **Caveat:** Apple only attributes `ct` when the link also carries the provider token `pt`
    /// from App Store Connect (Analytics → Campaigns). Fetching that is the one step of this
    /// loop an agent can't do — see docs/ANALYTICS.md's "Install attribution" note for the
    /// one-line change that turns it on.
    static func storeURL(campaign: String) -> URL {
        var c = URLComponents(string: "https://apps.apple.com/app/id\(appStoreID)")!
        c.queryItems = [URLQueryItem(name: "ct", value: campaign)]
        // Fixed literal + a percent-encoded token; cannot fail.
        return c.url ?? URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
    }

    static func compose(headline: String, board: String? = nil,
                        detail: String, campaign: String) -> String {
        var lines = [headline]
        if let board, !board.isEmpty { lines.append(board) }
        lines.append(detail)
        lines.append(storeURL(campaign: campaign).absoluteString)
        return lines.joined(separator: "\n")
    }

    /// Grouped thousands. Every score in a shared message goes through this — an ungrouped
    /// `2300` reads as a year, and having one surface say "1,240 pts" while the next says
    /// "2300 pts" makes the set look assembled by different people, which it was.
    static func points(_ score: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: score)) ?? String(score)
    }

    /// 🟩/⬛ marks, `perLine` to a row. The Grid's 3×3 and Keep 4's 4+4 are the same idea at
    /// different widths, so they share one builder rather than two hand-rolled `joined()` chains.
    static func emojiRow(_ hits: [Bool], perLine: Int) -> String {
        let marks = hits.map { $0 ? "🟩" : "⬛" }
        guard perLine > 0 else { return marks.joined() }
        return stride(from: 0, to: marks.count, by: perLine)
            .map { marks[$0..<min($0 + perLine, marks.count)].joined() }
            .joined(separator: "\n")
    }
}
