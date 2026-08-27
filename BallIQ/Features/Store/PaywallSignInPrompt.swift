import Foundation

/// When the paywall asks a player to sign in — and, more importantly, when it must not.
///
/// Split out of `PaywallView` as plain functions because the interesting property here isn't
/// visual, it's a rule about the purchase funnel, and a rule that lives only inside a `body`
/// can't be held in place by anything. SwiftUI renders its text into `CGDrawingView`s with no
/// accessibility labels materialised, so a hosted test genuinely cannot read the rendered
/// screen back; the choice is between asserting on a PNG nobody looks at and lifting the
/// decisions to somewhere assertions can reach. Same reasoning as
/// `PaywallView.failureProperties`.
///
/// **The rule.** A purchase made while signed out carries no `appAccountToken`, so it can't be
/// tied to a BallIQ account server-side, and Apple never starts supplying one later — which is
/// why `public.entitlements` was empty while purchases were happening (see
/// `RepositoryContainer.claimEntitlements`). The tempting fix is to require an account before
/// selling. Measured against production on 2026-08-26 that is a bad trade by an order of
/// magnitude: 254 `paywall_viewed` events, 21 of them from signed-in users. A gate would stand
/// in front of 92% of the people who reach this screen to solve a problem they do not have —
/// on-device entitlement works without an account and restores on any device with the same
/// Apple Account — and would invite a Guideline 5.1.1(v) argument, since none of the five
/// things Pro unlocks is account-based.
///
/// So the offer is made twice and enforced never: quietly before the sale, properly after it.
enum PaywallSignInPrompt {

    /// Offer the collapsed nudge above the plans — only to a guest. A signed-in player's
    /// purchases already carry their `appAccountToken`; there is nothing to claim, and asking
    /// anyway reads as a bug.
    static func offersSignIn(isSignedIn: Bool) -> Bool { !isSignedIn }

    /// Ask properly once a guest has actually bought something.
    ///
    /// After, not before: there is no conversion left to risk, and the pitch is finally
    /// something the player wants (keep what you just paid for) rather than a hoop. Never fires
    /// for a signed-in buyer, and never for a purchase that didn't complete — a sign-in screen
    /// after a cancelled purchase would read as the app having charged them.
    static func promptsAfterPurchase(purchased: Bool, isSignedIn: Bool) -> Bool {
        purchased && !isSignedIn
    }

    /// Whether the buy buttons are live.
    ///
    /// `isSignedIn` is accepted and deliberately ignored, and that is the entire point of the
    /// function: it is the one place a future "just make them sign in first" change would have
    /// to land, and `PaywallSignInPromptTests` asserts the answer is identical for both values.
    /// Only a purchase already in flight disables them.
    static func canPurchase(isSignedIn: Bool, purchaseInFlight: Bool) -> Bool {
        !purchaseInFlight
    }
}
