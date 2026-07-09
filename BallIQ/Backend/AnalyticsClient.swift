import Foundation

/// The app's event vocabulary (M15) — deliberately small; a handful of well-chosen funnel
/// events beats instrumenting every tap. Raw values are the `events.event_name` strings the
/// queries in docs/ANALYTICS.md group by, so treat them as a stable schema.
enum AnalyticsEvent: String {
    case onboardingCompleted   = "onboarding_completed"
    case signInCompleted       = "sign_in_completed"
    case gameStarted           = "game_started"
    case gameCompleted         = "game_completed"
    case puzzlePublished       = "puzzle_published"
    case communityPuzzlePlayed = "community_puzzle_played"
    case shareTapped           = "share_tapped"
    case reportFiled           = "report_filed"
    case purchaseCompleted     = "purchase_completed"
}

/// First-party, fire-and-forget event logging to the `events` table. Mirrors
/// `SupabaseClient`'s thin-REST shape (no third-party SDK, matching the app's hand-rolled
/// backend convention). A write must never block or fail a user action: `log` detaches
/// immediately and every failure is swallowed — same posture as `recordCommunityPlay`.
final class AnalyticsClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    /// `userID` is captured at call time (nil → signed-out event row; the RLS policy
    /// accepts both). Properties are flat strings by design — keep them queryable.
    func log(_ event: AnalyticsEvent, _ properties: [String: String] = [:], userID: String?) {
        guard let body = try? Self.encodeRow(event: event, properties: properties, userID: userID)
        else { return }
        Task { [client] in
            let req = client.restRequest(table: "events", method: "POST",
                                         body: body, prefer: "return=minimal")
            try? await client.perform(req)
        }
    }

    /// Pure row encoding, split out for tests (same pattern as `SupabaseClient`'s
    /// unit-testable request building). PostgREST bulk-insert array shape.
    static func encodeRow(event: AnalyticsEvent, properties: [String: String],
                          userID: String?) throws -> Data {
        var row: [String: Any] = ["event_name": event.rawValue, "properties": properties]
        if let userID { row["user_id"] = userID }
        return try JSONSerialization.data(withJSONObject: [row], options: [.sortedKeys])
    }
}
