import Foundation

struct Season: Decodable, Equatable {
    let id: Int
    let startsAt: Date
    let endsAt: Date
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }
}

/// The signed-in player's row in their current cohort.
struct CohortMembership: Decodable, Equatable {
    let cohortId: Int
    let seasonId: Int
    let weeklyXp: Int
    let priorZone: String?

    enum CodingKeys: String, CodingKey {
        case cohortId = "cohort_id"
        case seasonId = "season_id"
        case weeklyXp = "weekly_xp"
        case priorZone = "prior_zone"
    }
}

/// One row of `cohort_members`, before the profile (username/avatar) join.
private struct CohortMemberRow: Decodable {
    let userId: String
    let weeklyXp: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case weeklyXp = "weekly_xp"
    }
}

/// Promotion/relegation zone within a ~30-player cohort standings list (brief: top 5 promote,
/// bottom 5 relegate). Computed client-side from rank, same cutoffs as the rollover Edge Function.
enum CohortZone { case promote, relegate, hold }

/// Pure zone/cutoff/schedule math for Leagues, pulled out of `CohortRepository` so the
/// standings computation, the zone legend, and the How-it-works sheet all read from one
/// place — a cohort of 9 quoting "Top 5" in the legend but "Top 4" in the sheet would be a
/// visible contradiction, not just duplicated logic.
enum LeagueRules {
    static let maxPerZone = 5

    /// `min(5, n/2)` on both ends — identical math to the `weekly-cohort-rollover` Edge
    /// Function, so a half-empty cohort never promotes/relegates more than half its field.
    static func cutoffs(memberCount: Int) -> (promote: Int, relegate: Int) {
        let cutoff = min(maxPerZone, max(0, memberCount) / 2)
        return (cutoff, cutoff)
    }

    /// Zone for a 0-based standings rank (0 = first place), given the cohort's total size.
    static func zone(rankIndex: Int, memberCount: Int) -> CohortZone {
        let (promote, relegate) = cutoffs(memberCount: memberCount)
        if rankIndex < promote { return .promote }
        if rankIndex >= memberCount - relegate { return .relegate }
        return .hold
    }

    /// "Top 5 move up" — honest for small cohorts (n=9 reads "Top 4"), so the legend never
    /// promises a headcount the standings bars don't actually show.
    static func promoteLine(memberCount: Int) -> String {
        "Top \(cutoffs(memberCount: memberCount).promote) move up"
    }

    static func relegateLine(memberCount: Int) -> String {
        "Bottom \(cutoffs(memberCount: memberCount).relegate) move down"
    }

    /// The legend row and the countdown card's sub-line share this exact phrasing so the two
    /// can't drift into slightly different claims about the same cohort.
    static func summaryLine(memberCount: Int) -> String {
        "\(promoteLine(memberCount: memberCount)) · \(relegateLine(memberCount: memberCount))"
    }

    /// Next Monday 05:00 UTC strictly after `date` — mirrors the `0 5 * * 1` cron schedule
    /// driving `weekly-cohort-rollover` (see `supabase/migrations/0001_schedule_edge_functions.sql`),
    /// so the "league starts Monday" countdown can never promise a time the server doesn't
    /// actually roll over at.
    static func nextRollover(after date: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let weekday = utc.component(.weekday, from: date) // 1 = Sunday, 2 = Monday, ...
        let daysUntilMonday = (2 - weekday + 7) % 7
        let startOfCandidateDay = utc.date(byAdding: .day, value: daysUntilMonday, to: utc.startOfDay(for: date))!
        let candidate = utc.date(byAdding: .hour, value: 5, to: startOfCandidateDay)!
        return candidate > date ? candidate : utc.date(byAdding: .day, value: 7, to: candidate)!
    }
}

/// A standings row ready to display: cohort member + their public profile fields.
struct CohortStandingRow: Identifiable, Equatable {
    let userId: String
    var id: String { userId }
    let username: String?
    let avatar: String?
    let weeklyXp: Int
    var rank: Int = 0
    var zone: CohortZone = .hold
    var isMe: Bool = false

    var displayName: String { username ?? "Player" }
}

private struct ProfileRow: Decodable {
    let id: String
    let username: String?
    let avatar: String?
}

/// Reads cohort/season state and writes weekly XP. No local/offline mode — leagues are
/// inherently server-side (mirrors `CommunityPuzzleRepository`'s remote-only shape).
final class CohortRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func myMembership(userID: String) async -> CohortMembership? {
        let items = [
            URLQueryItem(name: "select", value: "cohort_id,season_id,weekly_xp,prior_zone"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "order", value: "joined_at.desc"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let rows: [CohortMembership]? = try? await client.select("cohort_members", query: items)
        return rows?.first
    }

    func season(id: Int) async -> Season? {
        let items = [URLQueryItem(name: "select", value: "id,starts_at,ends_at,status"),
                     URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "limit", value: "1")]
        let rows: [Season]? = try? await client.select("seasons", query: items)
        return rows?.first
    }

    /// Standings for a cohort, ranked by weekly XP, with promote/relegate zones applied
    /// using the same top-5/bottom-5 cutoffs as the server rollover.
    func standings(cohortID: Int, meUserID: String) async -> [CohortStandingRow] {
        let memberItems = [
            URLQueryItem(name: "select", value: "user_id,weekly_xp"),
            URLQueryItem(name: "cohort_id", value: "eq.\(cohortID)"),
            URLQueryItem(name: "order", value: "weekly_xp.desc"),
        ]
        guard let members: [CohortMemberRow] = try? await client.select("cohort_members", query: memberItems),
              !members.isEmpty else { return [] }

        let ids = members.map(\.userId).joined(separator: ",")
        let profileItems = [URLQueryItem(name: "select", value: "id,username,avatar"),
                             URLQueryItem(name: "id", value: "in.(\(ids))")]
        let profiles: [ProfileRow] = (try? await client.select("profiles", query: profileItems)) ?? []
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

        let n = members.count
        return members.enumerated().map { index, member in
            let zone = LeagueRules.zone(rankIndex: index, memberCount: n)
            let profile = profileByID[member.userId]
            return CohortStandingRow(userId: member.userId, username: profile?.username,
                                     avatar: profile?.avatar, weeklyXp: member.weeklyXp,
                                     rank: index + 1, zone: zone, isMe: member.userId == meUserID)
        }
    }

    /// Adds to the caller's weekly XP via the `bump_weekly_xp` RPC (no-op if not in an active cohort).
    func bumpWeeklyXP(_ amount: Int) async {
        struct Args: Encodable { let amount: Int }
        try? await client.rpc("bump_weekly_xp", args: Args(amount: amount))
    }
}
