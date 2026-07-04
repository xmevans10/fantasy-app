import Foundation

/// One user's report of a community puzzle, as read back from `community_reports`
/// (RLS: admins see every row, everyone else only their own).
struct CommunityReport: Decodable, Equatable {
    let puzzleId: String
    let reporterId: String
    let reason: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case reason
        case puzzleId = "puzzle_id"
        case reporterId = "reporter_id"
        case createdAt = "created_at"
    }
}

/// Client-side mirror of the moderation rules enforced server-side in supabase/schema.sql
/// (`auto_hide_reported_puzzle` trigger). Pure functions — the review queue groups raw
/// report rows through here, independent of the network layer.
enum ModerationPolicy {
    /// Distinct reporters required before a puzzle is auto-hidden from the public feed.
    /// Keep in sync with the `reporters >= 3` check in the schema's trigger.
    static let autoHideThreshold = 3

    static func shouldAutoHide(distinctReporters: Int) -> Bool {
        distinctReporters >= autoHideThreshold
    }

    /// A puzzle's aggregated reports, ready for the review queue.
    struct ReviewCase: Equatable, Identifiable {
        let puzzleId: String
        /// Each reporter counts once, matching the trigger's `count(distinct reporter_id)`.
        let distinctReporters: Int
        /// Deduplicated reasons, most recent first.
        let reasons: [String]
        /// ISO-8601 string of the newest report (lexicographic order == chronological).
        let latestReportAt: String

        var id: String { puzzleId }
        var meetsThreshold: Bool { ModerationPolicy.shouldAutoHide(distinctReporters: distinctReporters) }
    }

    /// Groups raw report rows into per-puzzle cases, ordered most-reported first
    /// (ties broken by newest report), so the queue surfaces the worst offenders on top.
    static func reviewCases(from reports: [CommunityReport]) -> [ReviewCase] {
        Dictionary(grouping: reports, by: \.puzzleId)
            .map { puzzleId, rows -> ReviewCase in
                let newestFirst = rows.sorted { $0.createdAt > $1.createdAt }
                var seen = Set<String>()
                let reasons = newestFirst.compactMap(\.reason)
                    .filter { seen.insert($0.lowercased()).inserted }
                return ReviewCase(puzzleId: puzzleId,
                                  distinctReporters: Set(rows.map(\.reporterId)).count,
                                  reasons: reasons,
                                  latestReportAt: newestFirst.first?.createdAt ?? "")
            }
            .sorted {
                $0.distinctReporters != $1.distinctReporters
                    ? $0.distinctReporters > $1.distinctReporters
                    : $0.latestReportAt > $1.latestReportAt
            }
    }
}
