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
    static func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound]),
              granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
