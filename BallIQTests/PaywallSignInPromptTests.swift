import XCTest
import SwiftUI
@testable import BallIQ

/// Cover for the sign-in prompts added to the paywall alongside the guest-purchase claim path
/// (`EntitlementClaimTests` covers the server half).
///
/// These exist to hold one design decision in place, because it is the one a later change would
/// most plausibly undo: **the paywall offers sign-in, and never requires it.** The pressure to
/// require it is real — a purchase made signed out can't be attributed to an account
/// server-side — but production on 2026-08-26 priced that fix at 92% of paywall traffic (254
/// `paywall_viewed`, 21 signed in), to solve something the buyer doesn't experience, while
/// picking an argument with Guideline 5.1.1(v).
@MainActor
final class PaywallSignInPromptTests: XCTestCase {

    // MARK: - The invariant: sign-in state must never gate a purchase

    /// The load-bearing test. `canPurchase` takes `isSignedIn` and must return the same answer
    /// for both values — a gate added here is exactly the regression this suite exists to catch.
    func testSignInStateCannotDisableTheBuyButtons() {
        for inFlight in [true, false] {
            XCTAssertEqual(
                PaywallSignInPrompt.canPurchase(isSignedIn: true, purchaseInFlight: inFlight),
                PaywallSignInPrompt.canPurchase(isSignedIn: false, purchaseInFlight: inFlight),
                "whether a player is signed in must not change whether they can buy "
                + "(purchaseInFlight: \(inFlight))")
        }
    }

    /// A guest — the overwhelming majority of this screen's traffic — can buy.
    func testAGuestCanPurchase() {
        XCTAssertTrue(PaywallSignInPrompt.canPurchase(isSignedIn: false, purchaseInFlight: false))
    }

    /// The one thing that legitimately disables them: a purchase already running, so a
    /// double-tap can't start two.
    func testAPurchaseInFlightDisablesTheButtons() {
        XCTAssertFalse(PaywallSignInPrompt.canPurchase(isSignedIn: false, purchaseInFlight: true))
        XCTAssertFalse(PaywallSignInPrompt.canPurchase(isSignedIn: true, purchaseInFlight: true))
    }

    // MARK: - The pre-purchase nudge

    func testTheNudgeIsOfferedToAGuest() {
        XCTAssertTrue(PaywallSignInPrompt.offersSignIn(isSignedIn: false))
    }

    /// A signed-in player's purchases already carry an `appAccountToken`. Nothing to claim, so
    /// nothing to ask — being nagged to do something you've already done reads as a bug.
    func testTheNudgeIsHiddenFromASignedInPlayer() {
        XCTAssertFalse(PaywallSignInPrompt.offersSignIn(isSignedIn: true))
    }

    // MARK: - The post-purchase ask

    /// The moment the whole design turns on: they've paid, there's no sale left to lose, and
    /// the ask is finally in their interest.
    func testAGuestIsAskedToSignInAfterBuying() {
        XCTAssertTrue(PaywallSignInPrompt.promptsAfterPurchase(purchased: true, isSignedIn: false))
    }

    /// A cancelled or failed purchase must not raise it. A sign-in screen appearing after a
    /// purchase that didn't happen reads as though the app charged them anyway.
    func testAnUnsuccessfulPurchaseNeverRaisesThePrompt() {
        XCTAssertFalse(PaywallSignInPrompt.promptsAfterPurchase(purchased: false, isSignedIn: false))
        XCTAssertFalse(PaywallSignInPrompt.promptsAfterPurchase(purchased: false, isSignedIn: true))
    }

    /// Nothing to claim for a buyer who was already signed in — StoreKit stamped their
    /// `appAccountToken` at purchase time.
    func testASignedInBuyerIsNotInterrupted() {
        XCTAssertFalse(PaywallSignInPrompt.promptsAfterPurchase(purchased: true, isSignedIn: true))
    }

    // MARK: - Visual record
    //
    // The rules above are what's assertable; this is the part a person still has to look at.
    // SwiftUI draws its text into `CGDrawingView`s with no accessibility labels materialised in
    // a hosted test, so the rendered copy genuinely cannot be read back — a PNG is the honest
    // artifact, and it is captured rather than asserted on.

    func testRenderEverySignInStateForVisualReview() async throws {
        for (stage, name) in [(PaywallView.Stage.offer, "offer"),
                              (.offerWithSignInOpen, "offer_expanded"),
                              (.postPurchase, "post_purchase")] {
            let container = RepositoryContainer(auth: AuthService(client: nil), client: nil,
                                                store: StoreService(fetchStub: { _ in [] }))
            let window = try XCTUnwrap(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first,
                "no window in hosted test app")
            let host = UIHostingController(
                rootView: PaywallView(stage: stage).environmentObject(container))
            let previous = window.rootViewController
            window.rootViewController = host
            defer { window.rootViewController = previous }
            for _ in 0..<4 {
                await Task.yield()
                try await Task.sleep(nanoseconds: 300_000_000)
            }

            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("paywall_signin_\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("PAYWALL_SIGNIN_\(name.uppercased()): \(url.path)")
        }
    }
}
