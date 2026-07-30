import XCTest
@testable import BallIQ

/// Guards the strings that have to agree for native Google sign-in to work. Each lives somewhere
/// different — Swift source, Info.plist, and the Google Cloud console — and a mismatch fails at
/// runtime inside a web sheet, where the only symptom is a browser error the user reports as
/// "sign-in is broken".
///
/// The client shipped in the repo's stale `client_*.apps.googleusercontent.com.plist` was deleted
/// from Google Cloud, which surfaces mid-flow as "the OAuth client was deleted". Until a
/// replacement iOS client exists, `clientID` is empty and the Google button is hidden rather than
/// shown broken — these tests hold in both states so an unconfigured build stays shippable.
final class GoogleSignInTests: XCTestCase {

    private var declaredSchemes: [String] {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }

    /// The whole point of the empty default: nothing should attempt a flow against a client that
    /// doesn't exist, and the UI keys off this to hide the button.
    func testUnconfiguredClientIsReportedAsSuch() {
        XCTAssertEqual(GoogleSignIn.isConfigured, !GoogleSignIn.clientID.isEmpty)
    }

    /// Attempting sign-in while unconfigured must fail fast and locally, never open a sheet
    /// pointed at a dead client.
    func testAuthenticateFailsFastWhenUnconfigured() async {
        guard !GoogleSignIn.isConfigured else {
            return  // configured — covered by the assertions below instead
        }
        do {
            _ = try await GoogleSignIn.authenticate()
            XCTFail("must not start a Google flow without a client id")
        } catch {
            XCTAssertTrue(error is SupabaseError)
        }
    }

    /// Google requires an iOS client's redirect URI to be its reversed client id, and
    /// `redirectScheme` is written out literally rather than derived — this is what stops the two
    /// drifting when the id is replaced.
    func testRedirectSchemeMatchesTheClientID() throws {
        try XCTSkipUnless(GoogleSignIn.isConfigured, "no Google iOS client configured yet")
        let bare = GoogleSignIn.clientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        XCTAssertEqual(GoogleSignIn.redirectScheme, "com.googleusercontent.apps.\(bare)",
            "redirectScheme must be the reversed client id, or the sheet can never call back")
        XCTAssertEqual(GoogleSignIn.redirectURI, "\(GoogleSignIn.redirectScheme):/oauth2redirect")
    }

    /// `ASWebAuthenticationSession` can only return through a scheme the app declares. Without
    /// this entry the consent sheet completes and then hangs with no callback.
    func testRedirectSchemeIsRegisteredInInfoPlist() throws {
        try XCTSkipUnless(GoogleSignIn.isConfigured, "no Google iOS client configured yet")
        XCTAssertTrue(declaredSchemes.contains(GoogleSignIn.redirectScheme),
            "Info.plist must declare \(GoogleSignIn.redirectScheme) — declared: \(declaredSchemes)")
    }

    /// An iOS OAuth client, not a Web one. A Web client needs a secret this app cannot hold, and
    /// Google rejects PKCE-only requests from it — that mismatch is what broke the hosted flow.
    func testClientIDLooksLikeAGoogleOAuthClient() throws {
        try XCTSkipUnless(GoogleSignIn.isConfigured, "no Google iOS client configured yet")
        XCTAssertTrue(GoogleSignIn.clientID.hasSuffix(".apps.googleusercontent.com"),
                      "got \(GoogleSignIn.clientID)")
    }

    /// Sign in with Apple and any hosted-provider flow return through this one; it must stay
    /// registered regardless of Google's state.
    func testAppSchemeIsStillRegistered() {
        XCTAssertTrue(declaredSchemes.contains("balliq"))
    }
}
