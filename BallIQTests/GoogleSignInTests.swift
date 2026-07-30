import XCTest
@testable import BallIQ

/// Guards the three strings that have to agree for native Google sign-in to work at all. Each is
/// declared in a different place — Swift source, Info.plist, and the Google Cloud console — and a
/// mismatch fails at runtime inside a web sheet, where the only symptom is a browser error the
/// user reports as "sign-in is broken".
final class GoogleSignInTests: XCTestCase {

    /// Google requires an iOS client's redirect URI to be its reversed client id. `redirectScheme`
    /// is written out literally rather than derived, so this is what stops the two drifting.
    func testRedirectSchemeIsTheReversedClientID() {
        let bare = GoogleSignIn.clientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        XCTAssertEqual(GoogleSignIn.redirectScheme, "com.googleusercontent.apps.\(bare)")
    }

    /// `ASWebAuthenticationSession` can only return through a scheme the app actually declares.
    /// Without this entry the consent sheet completes and then hangs with no callback.
    func testRedirectSchemeIsRegisteredInInfoPlist() throws {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(declared.contains(GoogleSignIn.redirectScheme),
            "Info.plist must declare \(GoogleSignIn.redirectScheme) — declared: \(declared)")
    }

    /// The Supabase callback scheme has to stay registered too; Sign in with Apple and any
    /// remaining hosted-provider flow return through it.
    func testAppSchemeIsStillRegistered() {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(declared.contains("balliq"))
    }

    /// An iOS OAuth client id, not a Web one. A Web client would need a secret this app cannot
    /// hold, and Google rejects PKCE-only requests from it.
    func testClientIDLooksLikeAGoogleOAuthClient() {
        XCTAssertTrue(GoogleSignIn.clientID.hasSuffix(".apps.googleusercontent.com"),
                      "got \(GoogleSignIn.clientID)")
        XCTAssertEqual(GoogleSignIn.redirectURI, "\(GoogleSignIn.redirectScheme):/oauth2redirect")
    }
}
