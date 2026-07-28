import UIKit
import UserNotifications

extension Notification.Name {
    static let didRegisterDeviceToken = Notification.Name("didRegisterDeviceToken")
}

/// Forwards the APNs device token to `RepositoryContainer` via NotificationCenter (kept decoupled
/// from the SwiftUI app's `@StateObject` lifecycle, since the delegate is constructed first).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: .didRegisterDeviceToken, object: nil, userInfo: ["token": token])
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected until the APNs hand-off lands (Push Notifications capability + APNs key —
        // see prompts/M4-social-retention.md) or when running in Simulator, which can't register.
        print("Push registration failed (expected pre-APNs hand-off): \(error)")
    }
}

/// Requests notification permission and starts APNs registration. Delivery itself is server-side
/// (`supabase/functions/_shared/apns.ts`) — this only gets a device token into `device_tokens`.
@MainActor
enum PushNotificationManager {
    /// Prompts (once per install — iOS never re-asks) and registers on a grant. Returns the
    /// resulting status so the caller can log which way the prompt went; `@discardableResult`
    /// keeps the fire-and-forget call in Profile's settings card unchanged.
    @discardableResult
    static func requestAuthorizationAndRegister() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound]),
              granted else { return await currentAuthorizationStatus() }
        UIApplication.shared.registerForRemoteNotifications()
        return await currentAuthorizationStatus()
    }

    /// Re-asks APNs for a token on every launch when permission is *already* granted.
    ///
    /// Without this, a token was only ever obtained by tapping "Enable push notifications" in
    /// Profile, and `RepositoryContainer.pushPendingDeviceTokenIfNeeded()` drops it unless the
    /// user happens to be signed in at that moment (`device_tokens.user_id` is NOT NULL). So a
    /// grant made while signed out was lost at process exit and the row never appeared — which
    /// is why production had 1 device token across 4 profiles on 2026-07-27, and why the hourly
    /// `notify-streak-risk` cron had a candidate pool of one device. Re-registering at launch
    /// makes the token arrive again on every cold start, so it lands the moment the user signs
    /// in. Apple's own guidance is the same: register on every launch, tokens are not stable.
    static func registerIfAuthorized() async {
        switch await currentAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

extension UNAuthorizationStatus {
    /// Stable analytics value for `app_opened.push` / `push_primer_answered.status`. Spelled out
    /// rather than using the enum's Int raw value so a future OS adding a case can't renumber
    /// history in the warehouse.
    var analyticsValue: String {
        switch self {
        case .notDetermined: return "not_determined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown"
        }
    }
}
