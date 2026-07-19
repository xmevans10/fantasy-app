import Foundation
import StoreKit

/// Asks for an App Store rating only at the two pride moments — an Immaculate Grid (9/9)
/// or reaching a 7-day streak — and never more than once every 60 days. Apple already caps
/// the system sheet at 3 shows/year and suppresses it after the user has rated, so the
/// only job here is picking GOOD moments instead of interrupting a loss (docs/MARKETING.md
/// flagged this as the highest-ROI product-marketing item).
enum ReviewPrompter {
    private static let lastPromptKey = "reviewPrompt.lastRequestDate"
    private static let minInterval: TimeInterval = 60 * 24 * 3600

    /// True when the moment qualifies AND we haven't asked recently. Callers then invoke
    /// SwiftUI's `requestReview` themselves (it's an Environment value, unreachable here).
    static func shouldAsk(immaculateGrid: Bool = false, streak: Int = 0,
                          defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard immaculateGrid || streak >= 7 else { return false }
        if let last = defaults.object(forKey: lastPromptKey) as? Date,
           now.timeIntervalSince(last) < minInterval {
            return false
        }
        defaults.set(now, forKey: lastPromptKey)
        return true
    }
}
