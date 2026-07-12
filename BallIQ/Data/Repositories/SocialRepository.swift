import Foundation

enum FriendsError: Error { case notFound, cannotFriendSelf, alreadyLinked }

/// One `friends` edge, exactly as stored (requester → addressee). Views should mostly
/// consume `FriendRow` (edge + resolved profile) from `SocialRepository` instead.
struct FriendEdge: Decodable, Equatable {
    let requesterId: String
    let addresseeId: String
    let status: String       // 'pending' | 'accepted'

    var isAccepted: Bool { status == "accepted" }
    func otherID(me: String) -> String { requesterId == me ? addresseeId : requesterId }
    func isIncomingPending(me: String) -> Bool { status == "pending" && addresseeId == me }
    func isOutgoingPending(me: String) -> Bool { status == "pending" && requesterId == me }
}

/// A friend edge joined with the other side's public identity — what lists render.
struct FriendRow: Identifiable, Equatable {
    let edge: FriendEdge
    let userID: String       // the *other* user
    let username: String?
    let avatar: String?
    var id: String { userID }
}

/// The `public_profile(target)` RPC's projection — deliberately leaderboard-grade only
/// (username, avatar, per-sport ratings, streak, xp). Never carries email/entitlements.
struct PublicProfile: Decodable, Equatable {
    let id: String
    let username: String?
    let avatar: String?
    let streak: Int
    let xp: Int
    /// Keyed by `Sport.rawValue`.
    let ratings: [String: Int]

    func rating(for sport: Sport) -> Int { ratings[sport.rawValue] ?? 1000 }
    /// The sport this player is strongest at (ties favor `Sport.allCases` order, matching
    /// `ProfileView.bestSport`'s convention).
    var bestSport: Sport {
        Sport.allCases.reduce(Sport.nfl) { rating(for: $1) > rating(for: $0) ? $1 : $0 }
    }
}

/// A user's own editable identity (`profiles.username` / `profiles.avatar`).
struct ProfileIdentity: Equatable {
    var username: String?
    var avatar: String?
    static let empty = ProfileIdentity(username: nil, avatar: nil)
}

/// Friends graph + public-profile reads. Remote-only (mirrors `VersusRepository`'s shape):
/// the social graph is inherently server-mediated, so there is no local fallback.
final class SocialRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    // MARK: - Friends graph

    /// Every edge the caller participates in (both statuses, both directions).
    func edges(me: String) async -> [FriendEdge] {
        (try? await client.select("friends", query: [
            URLQueryItem(name: "select", value: "requester_id,addressee_id,status"),
            URLQueryItem(name: "or", value: "(requester_id.eq.\(me),addressee_id.eq.\(me))"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ])) ?? []
    }

    /// Edges resolved with the other side's username/avatar, for direct rendering.
    func friendRows(me: String) async -> [FriendRow] {
        let edges = await edges(me: me)
        guard !edges.isEmpty else { return [] }
        let ids = Set(edges.map { $0.otherID(me: me) }).joined(separator: ",")
        struct ProfileRow: Decodable { let id: String; let username: String?; let avatar: String? }
        let profiles: [ProfileRow] = (try? await client.select("profiles", query: [
            URLQueryItem(name: "select", value: "id,username,avatar"),
            URLQueryItem(name: "id", value: "in.(\(ids))"),
        ])) ?? []
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return edges.map { edge in
            let other = edge.otherID(me: me)
            return FriendRow(edge: edge, userID: other,
                             username: byID[other]?.username, avatar: byID[other]?.avatar)
        }
    }

    /// Sends a friend request by exact username. Pre-checks the pair in both directions —
    /// the DB's least/greatest unique index is the hard backstop, but a clean thrown error
    /// beats surfacing a raw 409 to the UI.
    func sendRequest(toUsername username: String, me: String) async throws {
        struct Row: Decodable { let id: String }
        let rows: [Row] = (try? await client.select("profiles", query: [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "username", value: "eq.\(username)"),
            URLQueryItem(name: "limit", value: "1"),
        ])) ?? []
        guard let target = rows.first?.id else { throw FriendsError.notFound }
        try await sendRequest(toUserID: target, me: me)
    }

    func sendRequest(toUserID target: String, me: String) async throws {
        guard target != me else { throw FriendsError.cannotFriendSelf }
        let existing: [FriendEdge] = (try? await client.select("friends", query: [
            URLQueryItem(name: "select", value: "requester_id,addressee_id,status"),
            URLQueryItem(name: "or", value:
                "(and(requester_id.eq.\(me),addressee_id.eq.\(target)),and(requester_id.eq.\(target),addressee_id.eq.\(me)))"),
        ])) ?? []
        guard existing.isEmpty else { throw FriendsError.alreadyLinked }
        struct Insert: Encodable { let requesterId: String; let addresseeId: String }
        try await client.insert("friends", values: Insert(requesterId: me, addresseeId: target))
    }

    /// Accept (`true`) or decline-and-delete (`false`) an incoming pending request.
    func respond(toRequester requester: String, accept: Bool) async {
        struct Args: Encodable { let pRequester: String; let pAccept: Bool
            enum CodingKeys: String, CodingKey { case pRequester = "p_requester", pAccept = "p_accept" }
        }
        _ = try? await client.rpc("respond_friend_request", args: Args(pRequester: requester, pAccept: accept))
    }

    /// Removes the edge in either direction (unfriend, or cancel an outgoing request).
    func removeFriend(userID: String) async {
        struct Args: Encodable { let pOther: String
            enum CodingKeys: String, CodingKey { case pOther = "p_other" }
        }
        _ = try? await client.rpc("remove_friend", args: Args(pOther: userID))
    }

    // MARK: - Public profiles

    /// Another player's public projection via the `public_profile` RPC (see schema.sql —
    /// ratings/progress RLS stays own-only; this is the one sanctioned cross-user read).
    func publicProfile(userID: String) async -> PublicProfile? {
        struct Args: Encodable { let target: String }
        guard let data = try? await client.rpc("public_profile", args: Args(target: userID)),
              !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(PublicProfile.self, from: data)
    }
}
