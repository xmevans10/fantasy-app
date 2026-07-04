import Foundation

/// Ordering for the Community "This Week" sort (M13). Pure — the 7-day play counts come
/// from the `weekly_play_counts` RPC (see supabase/schema.sql); this just ranks with them.
enum CommunityTrending {
    /// Most 7-day plays first; ties (including the zero-play tail) fall back to newest
    /// first, so with no counts at all the result degrades to exactly the recent order.
    static func sorted(items: [CommunitySummary], weeklyPlays: [String: Int]) -> [CommunitySummary] {
        items.sorted {
            let a = weeklyPlays[$0.id] ?? 0
            let b = weeklyPlays[$1.id] ?? 0
            if a != b { return a > b }
            return $0.createdAt > $1.createdAt   // ISO-8601: lexicographic == chronological
        }
    }
}
