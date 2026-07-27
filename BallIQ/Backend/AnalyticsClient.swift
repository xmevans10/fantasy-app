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
    // Purchase funnel. `purchaseCompleted` shipped alone, which meant the only measurable
    // point was the very bottom — you could see a sale but never how many people reached the
    // paywall, from where, or where they dropped. These three make it a funnel:
    // paywallViewed -> purchaseAttempted -> purchaseCompleted | purchaseFailed.
    /// Carries `trigger` — WHICH gate sent the user here (see `PaywallTrigger`). Five
    /// different surfaces present the paywall; without this they're indistinguishable, and
    /// "which gate actually sells Pro" is the first question worth asking of this data.
    case paywallViewed         = "paywall_viewed"
    case purchaseAttempted     = "purchase_attempted"
    /// Carries `reason`: `cancelled` (StoreKit returned without a transaction — usually the
    /// user dismissing Apple's sheet) or `error` (the purchase threw). Distinguishing them
    /// matters: cancellation is a pricing/intent signal, an error is a bug.
    case purchaseFailed        = "purchase_failed"
    case purchaseCompleted     = "purchase_completed"
}

/// Where a paywall presentation came from. String-backed because it lands in
/// `events.properties->>'trigger'` and is grouped by in SQL — treat these as a stable schema,
/// same rule as `AnalyticsEvent`'s raw values.
enum PaywallTrigger: String {
    case sportPicker      = "sport_picker"       // a Pro-locked sport chip on a setup screen
    case grid             = "grid"               // The Grid (Pro-only format)
    case hardMode         = "hard_mode"          // Keep4 hard mode
    case archive          = "archive"            // Browse / full archive
    case overUnderLives   = "over_under_lives"   // out of Over/Under lives
    /// The `-screenshotPaywall` debug hook and any future site that hasn't been attributed.
    /// A real `other` in production means a presentation site was added without a trigger.
    case other            = "other"
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
