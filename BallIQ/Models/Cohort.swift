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
        let promoteCutoff = min(5, n / 2)
        let relegateCutoff = min(5, n / 2)

        return members.enumerated().map { index, member in
            let zone: CohortZone = index < promoteCutoff ? .promote
                : index >= n - relegateCutoff ? .relegate : .hold
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
