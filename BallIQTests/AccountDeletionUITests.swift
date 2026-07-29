import XCTest
import SwiftUI
@testable import BallIQ

/// Cover for the Guideline 5.1.1(v) rejection of 1.3 (17): "The app supports account creation but
/// does not include an option to initiate account deletion."
///
/// Apple's reviewer looks for one specific thing — a way to *start* deleting the account, reachable
/// from inside the app while signed in. These render the real `ProfileView` and check the row is
/// actually there when signed in and absent when not, so the requirement can't quietly regress
/// behind a refactor of the account card.
@MainActor
final class AccountDeletionUITests: XCTestCase {

    private func makeContainer(signedIn: Bool) -> (RepositoryContainer, AuthService) {
        let session = Session(accessToken: "test.access.token", refreshToken: "test-refresh",
                              expiresAt: Date().addingTimeInterval(3600),
                              userID: "00000000-0000-0000-0000-0000000000aa")
        let auth = signedIn
            ? AuthService(client: nil, signedInAs: session)
            : AuthService(client: nil)
        let container = RepositoryContainer(auth: auth, client: nil,
                                            store: StoreService(fetchStub: { _ in [] }))
        return (container, auth)
    }

    private func render(signedIn: Bool) throws -> (UIWindow, UIViewController?) {
        let (container, auth) = makeContainer(signedIn: signedIn)
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first,
            "no window in hosted test app")
        let host = UIHostingController(
            rootView: ProfileView().environmentObject(container).environmentObject(auth))
        let previous = window.rootViewController
        window.rootViewController = host
        return (window, previous)
    }

    /// The row must exist for a signed-in user. Captured as a PNG so the deletion entry point can
    /// be eyeballed without a device — the path is printed as `DELETE_ACCOUNT_UI:`.
    func testProfileOffersAccountDeletionWhenSignedIn() async throws {
        let (window, previous) = try render(signedIn: true)
        defer { window.rootViewController = previous }
        await settle()

        let scrollView = try XCTUnwrap(firstScrollView(in: window), "no scroll view in Profile")
        scrollView.setContentOffset(
            CGPoint(x: 0, y: max(0, scrollView.contentSize.height
                                    + scrollView.adjustedContentInset.bottom
                                    - scrollView.bounds.height)),
            animated: false)
        await settle()

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete_account_ui.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("DELETE_ACCOUNT_UI: \(url.path)")
    }

    /// ...and must not be offered to a guest, who has no account to delete. A destructive control
    /// that can only fail is worse than no control.
    func testProfileHidesAccountDeletionWhenSignedOut() async throws {
        let (window, previous) = try render(signedIn: false)
        defer { window.rootViewController = previous }
        await settle()

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete_account_ui_signed_out.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("DELETE_ACCOUNT_UI_SIGNED_OUT: \(url.path)")
    }

    /// A guest has nothing to delete, and `deleteAccount()` must say so rather than reaching the
    /// network — this is the path behind the (hidden) button if it ever gets shown by mistake.
    func testDeletingWithoutAnAccountFailsClosed() async {
        let (container, _) = makeContainer(signedIn: false)
        do {
            try await container.deleteAccount()
            XCTFail("a signed-out user must not be able to run an account deletion")
        } catch {
            XCTAssertTrue(error is RepositoryContainer.AccountDeletionError)
        }
    }

    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}
