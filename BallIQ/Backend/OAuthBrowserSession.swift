import AuthenticationServices
import UIKit

/// Runs a Supabase-hosted OAuth provider (Google, etc.) in the system browser sheet and returns
/// the `balliq://auth-callback#...` redirect URL. `ASWebAuthenticationSession` intercepts the
/// registered `balliq` scheme itself — no app-level `onOpenURL` handling needed.
@MainActor
final class OAuthBrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// `ephemeral: false` lets the sheet see the user's existing Google session, so they get a
    /// one-tap account picker instead of an empty "Email or phone" field. Ephemeral was the
    /// default here and is the reason signing in with Google meant typing an address every
    /// time — it deliberately hides any cookie the user already has.
    static func run(url: URL, callbackScheme: String, ephemeral: Bool = false) async throws -> URL {
        try await OAuthBrowserSession().start(url: url, callbackScheme: callbackScheme, ephemeral: ephemeral)
    }

    private func start(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? SupabaseError.transport("Sign-in was cancelled"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = ephemeral
            self.session = session // retained on self for the duration of the flow
            if !session.start() {
                continuation.resume(throwing: SupabaseError.transport("Couldn't start sign-in"))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
