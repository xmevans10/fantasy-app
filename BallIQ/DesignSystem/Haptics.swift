import UIKit

/// Centralized haptics so feedback is consistent across formats.
enum Haptics {
    static func tap()    { impact(.light) }
    static func commit() { impact(.medium) }
    static func reject() { impact(.rigid) }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
