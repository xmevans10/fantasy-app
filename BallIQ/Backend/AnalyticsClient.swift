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
    // Viral loop. `share_tapped` shipped alone and unqualified, which made it unanswerable:
    // 6 taps, ever, with no way to tell which format produced them, what artifact went out, or
    // whether a single one led anywhere. These make it a loop you can compute a k-factor from:
    // shareTapped -> shareLinkOpened -> challengeStarted -> challengeCompleted.
    /// A challenge link resolved into the app. The **denominator's other half**: divided into
    /// `share_tapped` it is the loop's click-through, and there is no way to recover it after
    /// the fact, so it has to be logged at open time.
    case shareLinkOpened       = "share_link_opened"
    /// The recipient actually started the challenged board. Split from `shareLinkOpened`
    /// because the gap between them is a real, fixable funnel step (board missing for that
    /// day, Pro gate, they bounced) rather than noise.
    case challengeStarted      = "challenge_started"
    /// The recipient finished it. Carries `outcome` (`win`/`loss`/`tie`) — a loop where
    /// recipients always lose doesn't run twice.
    case challengeCompleted    = "challenge_completed"
    // Activation funnel. The loop above brings people in; these say whether the first session
    // goes anywhere. `onboarding_completed` already existed but had nothing before or after it,
    // so a drop-off had no location: app_opened -> onboarding_step_viewed -> first_game_started
    // -> first_game_completed, with `app_opened.day_index` carrying the return curve.
    /// Every launch. Carries `first_open` and `day_index` (whole local days since install), so
    /// next-day return is `day_index = 1` rather than a separate event that could disagree.
    case appOpened             = "app_opened"
    /// One row per first-run screen reached, carrying `step` (see `OnboardingStep`). Onboarding
    /// was previously all-or-nothing: 26 completions, no way to see who left on which screen.
    case onboardingStepViewed  = "onboarding_step_viewed"
    /// Fired at most once per install (see `ActivationState.markOnce`) — the activation moment
    /// the whole first session is judged against.
    case firstGameStarted      = "first_game_started"
    case firstGameCompleted    = "first_game_completed"
}

/// Which artifact left the app on a share tap. Separate from the game format because they answer
/// different questions: `format` says which game produces sharers, `artifact` says which *kind of
/// thing* spreads once it's out there. Immaculate Grid's whole growth story is that one artifact
/// (a spoiler-free emoji board + a link) outperformed everything else, and until this dimension
/// existed BallIQ could not have noticed the same thing happening.
enum ShareArtifact: String {
    /// Text: headline + a spoiler-free board picture + the App Store link. The one that travels.
    case challengeText = "challenge_text"
    /// A rendered PNG. Looks good, carries no link — a dead end by construction.
    case resultImage   = "result_image"
    /// A bare `balliq://play/<id>` deep link. Opens nothing for a recipient without the app.
    case puzzleLink    = "puzzle_link"
    case profileImage  = "profile_image"
}

extension AnalyticsEvent {
    /// The one place a `share_tapped` property bag is built, so every share site reports the
    /// same three dimensions under the same keys. Sites were previously free-form and had
    /// drifted to `surface`-only, which is why the existing data can't answer anything.
    ///
    /// - `surface`: where in the app the tap happened (`grid_result`, `profile`, …).
    /// - `format`: which game produced it — same vocabulary as `game_started.format`.
    /// - `artifact`: what actually left the app.
    static func shareProperties(surface: String, format: String, artifact: ShareArtifact,
                                extra: [String: String] = [:]) -> [String: String] {
        var props = ["surface": surface, "format": format, "artifact": artifact.rawValue]
        props.merge(extra) { _, new in new }
        return props
    }
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
