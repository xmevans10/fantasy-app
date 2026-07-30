import Foundation
import CryptoKit

/// Native Google sign-in: talks to Google directly with the project's **iOS** OAuth client and
/// PKCE, then hands the resulting `id_token` to GoTrue — the same `grant_type=id_token` exchange
/// Sign in with Apple already uses.
///
/// Replaces routing through Supabase's hosted `/auth/v1/authorize`, which had two visible
/// problems. Google renders the *redirect host* on its consent screen, and for the hosted flow
/// that host is `<project-ref>.supabase.co`, so users were asked to "continue to
/// nhccgufqwndtoasdbkhc.supabase.co" — a string that means nothing to them and looks like a
/// phishing page. And the hosted flow only lands back in the app if `balliq://auth-callback` is
/// on Supabase's redirect allow-list; when it isn't, GoTrue silently falls back to the project's
/// Site URL and the sheet dead-ends in a Safari error.
///
/// Going direct removes both: Google sees an iOS client whose consent screen shows the app, and
/// the redirect never leaves the device. No SDK — Google's iOS OAuth clients carry no secret and
/// authenticate with PKCE, which is a few dozen lines of URL building over the existing
/// `ASWebAuthenticationSession` helper.
enum GoogleSignIn {

    /// Public by design: an iOS OAuth client has no secret (that's why PKCE exists), and this id
    /// is visible in every authorization request the app makes. It must match the client listed
    /// in Supabase → Authentication → Providers → Google → **Authorized Client IDs**, or GoTrue
    /// will reject the `id_token` even though Google issued it happily.
    ///
    /// Replaced 2026-07-30. The previous id (`392561766080-2uhj6v08…`) had been **deleted from
    /// Google Cloud**, which Google reports mid-flow as "the OAuth client was deleted" — an error
    /// a user reads as the app being broken. If that ever recurs, blank this rather than leaving
    /// a dead id in place: `isConfigured` hides the Google button, which beats shipping one that
    /// always fails.
    static let clientID = "392561766080-cbmq70afurju5rj73qi2vaqi6htvmi6e.apps.googleusercontent.com"

    static var isConfigured: Bool { !clientID.isEmpty }

    /// Google requires the redirect URI of an iOS client to be its reversed client id. Written
    /// out rather than derived from `clientID`: the matching entry also has to be declared
    /// verbatim in Info.plist's `CFBundleURLTypes`, and two independent derivations of the same
    /// string is how they drift apart. `GoogleSignInTests` asserts they still agree.
    static let redirectScheme = "com.googleusercontent.apps.392561766080-cbmq70afurju5rj73qi2vaqi6htvmi6e"
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    struct Credentials {
        let idToken: String
        let nonce: String
    }

    /// Runs the consent sheet and returns a verified `id_token` plus the nonce it was bound to.
    static func authenticate() async throws -> Credentials {
        guard isConfigured else {
            throw SupabaseError.notConfigured
        }
        let verifier = AuthService.makeNonce(length: 64)
        let challenge = base64URLEncodedSHA256(of: verifier)
        let nonce = AuthService.makeNonce(length: 32)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            // `openid` is what makes Google return an id_token at all; GoTrue needs the email
            // claim to create or match the user.
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: nonce),
        ]

        let callback = try await OAuthBrowserSession.run(url: comps.url!,
                                                        callbackScheme: redirectScheme)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SupabaseError.transport("Google didn't return an authorization code")
        }

        return Credentials(idToken: try await exchange(code: code, verifier: verifier),
                           nonce: nonce)
    }

    /// Swaps the one-time code for an `id_token`. No client secret: the `code_verifier` is what
    /// proves this is the same app that started the flow.
    private static func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.transport("Google token exchange failed: \(detail)")
        }
        struct TokenResponse: Decodable { let idToken: String }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let token = try? decoder.decode(TokenResponse.self, from: data).idToken else {
            throw SupabaseError.decoding("No id_token in Google's token response")
        }
        return token
    }

    private static func base64URLEncodedSHA256(of input: String) -> String {
        Data(SHA256.hash(data: Data(input.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
