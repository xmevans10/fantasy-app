import Foundation
import CryptoKit

/// A Supabase auth session.
struct Session: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: String
    /// One-time code from `ASAuthorizationAppleIDCredential`, kept only for Sign in with Apple
    /// sessions. Unused today; see `AuthService.signInWithApple` for why it's captured. Optional
    /// with a default so sessions already in the Keychain from earlier builds still decode.
    var appleAuthorizationCode: String?

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) } // refresh 60s early
}

/// Thread-safe holder for the current access token. `SupabaseClient` reads this synchronously
/// from any thread, decoupled from the `@MainActor` `AuthService`.
final class TokenBox: TokenProvider {
    private let lock = NSLock()
    private var token: String?
    private var refresher: (@Sendable () async -> Void)?

    var accessToken: String? {
        lock.lock(); defer { lock.unlock() }; return token
    }
    func set(_ value: String?) {
        lock.lock(); token = value; lock.unlock()
    }
    /// Install the async hook (set once by `AuthService`) that renews an expired token.
    func onRefresh(_ block: @escaping @Sendable () async -> Void) {
        lock.lock(); refresher = block; lock.unlock()
    }
    /// Renew the token via the installed hook (called before a 401 retry); no-op if none.
    func refreshIfNeeded() async {
        lock.lock(); let block = refresher; lock.unlock()
        await block?()
    }
}

/// Owns auth state: native Sign in with Apple → Supabase session, persisted in the Keychain.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var session: Session?

    var isSignedIn: Bool { session != nil }
    var userID: String? { session?.userID }

    let tokenBox = TokenBox()
    private let client: SupabaseClient?
    private let sessionKey = "supabase.session"

    init(client: SupabaseClient?) {
        self.client = client
        // Let the client renew an expired access token before retrying a 401'd request.
        tokenBox.onRefresh { [weak self] in await self?.refreshIfNeeded() }
        if let data = Keychain.get(sessionKey)?.data(using: .utf8),
           let saved = try? JSONDecoder().decode(Session.self, from: data) {
            apply(saved)
        }
    }

    /// Test-only: a service that is already signed in, with **no Keychain write**. Rendering the
    /// signed-in Profile (and the DELETE ACCOUNT row Apple reviews) otherwise means persisting a
    /// fake session into the real Keychain, which hosted tests share with the actual app — that
    /// leaves a bogus session behind for the next manual launch.
    init(client: SupabaseClient?, signedInAs session: Session) {
        self.client = client
        self.session = session
        tokenBox.set(session.accessToken)
    }

    // MARK: - Sign in with Apple

    /// Exchange an Apple identity token (+ the raw nonce used to derive the request nonce) for a session.
    ///
    /// `authorizationCode` is stored, not sent: GoTrue doesn't need it, but Apple requires that
    /// an app deleting an account also revoke the user's Apple token
    /// (`POST appleid.apple.com/auth/revoke`), and revocation needs a refresh token obtained by
    /// exchanging this one-time code against an Apple client-secret JWT. That exchange is
    /// server-side work (Apple Services ID + private key + an edge function) that this build
    /// does not do — the in-app deletion flow Apple actually reviews ships first. Capturing the
    /// code now means the follow-on is a backend change only, instead of another round of
    /// auth plumbing plus a re-sign-in for every existing user.
    func signInWithApple(identityToken: String, rawNonce: String,
                         authorizationCode: String? = nil) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.authToken(grantType: "id_token", body: [
            "provider": "apple",
            "id_token": identityToken,
            "nonce": rawNonce
        ])
        var parsed = try Self.parseSession(from: data)
        parsed.appleAuthorizationCode = authorizationCode
        apply(parsed)
    }

    // MARK: - OAuth providers (Google, etc.)

    /// Sign in via a Supabase-hosted OAuth provider using the system browser sheet.
    /// `redirect_to` points at the app's registered `balliq` URL scheme.
    func signInWithProvider(_ provider: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        var comps = URLComponents(url: client.config.url.appendingPathComponent("auth/v1/authorize"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: "balliq://auth-callback")
        ]
        let callbackURL = try await OAuthBrowserSession.run(url: comps.url!, callbackScheme: "balliq")
        apply(try Self.parseSession(fromCallback: callbackURL))
    }

    /// GoTrue's hosted `/authorize` redirect returns tokens in the URL fragment
    /// (`#access_token=...&refresh_token=...&expires_in=...`) — a different shape than the
    /// JSON token endpoint `parseSession(from:)` handles, and with no `user` object, so the
    /// user id comes from the access token's `sub` claim instead.
    nonisolated static func parseSession(fromCallback url: URL) throws -> Session {
        guard let fragment = url.fragment else {
            throw SupabaseError.decoding("No fragment in OAuth callback")
        }
        let params = fragment.split(separator: "&").reduce(into: [String: String]()) { dict, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = parts[1].removingPercentEncoding else { return }
            dict[parts[0]] = value
        }
        guard let accessToken = params["access_token"],
              let refreshToken = params["refresh_token"],
              let expiresIn = params["expires_in"].flatMap(Int.init) else {
            throw SupabaseError.decoding(params["error_description"] ?? "Missing tokens in OAuth callback")
        }
        return Session(accessToken: accessToken, refreshToken: refreshToken,
                       expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
                       userID: try subClaim(ofJWT: accessToken))
    }

    /// Decodes the `sub` claim from a JWT's payload segment without verifying the signature
    /// (verification already happened server-side; this just reads the user id back out).
    nonisolated private static func subClaim(ofJWT token: String) throws -> String {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { throw SupabaseError.decoding("Malformed access token") }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+")
                                         .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else {
            throw SupabaseError.decoding("No sub claim in access token")
        }
        return sub
    }

    /// Refresh the access token when expired. Signs out if the refresh is rejected.
    func refreshIfNeeded() async {
        guard let client, let session, session.isExpired else { return }
        do {
            let data = try await client.authToken(grantType: "refresh_token",
                                                  body: ["refresh_token": session.refreshToken])
            var refreshed = try Self.parseSession(from: data)
            // The refresh response is GoTrue's, so it carries no Apple code — carry the stored
            // one forward or it would be lost the first time the access token expired, which is
            // within the hour.
            refreshed.appleAuthorizationCode = session.appleAuthorizationCode
            apply(refreshed)
        } catch {
            signOut()
        }
    }

    func signOut() {
        session = nil
        tokenBox.set(nil)
        Keychain.delete(sessionKey)
    }

    // MARK: - Helpers

    private func apply(_ session: Session) {
        self.session = session
        tokenBox.set(session.accessToken)
        if let data = try? JSONEncoder().encode(session), let str = String(data: data, encoding: .utf8) {
            Keychain.set(str, for: sessionKey)
        }
    }

    /// Pure GoTrue token-response → Session mapping (unit-testable, no network).
    nonisolated static func parseSession(from data: Data) throws -> Session {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Int
            let user: User
            struct User: Decodable { let id: String }
        }
        let r = try JSONDecoder.supabase.decode(TokenResponse.self, from: data)
        return Session(accessToken: r.accessToken,
                       refreshToken: r.refreshToken,
                       expiresAt: Date().addingTimeInterval(TimeInterval(r.expiresIn)),
                       userID: r.user.id)
    }

    // MARK: - Nonce (Sign in with Apple)

    /// A random nonce; pass `raw` to Supabase and `sha256(raw)` to the Apple request.
    nonisolated static func makeNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        for _ in 0..<length { result.append(charset[Int.random(in: 0..<charset.count)]) }
        return result
    }

    nonisolated static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
