import Foundation

/// The app's StoreKit product catalog — IDs must match `Products.storekit` (simulator
/// testing) and the live App Store Connect records (hand-off, see BALLIQ_SPEC.md M5).
enum StoreProduct: String, CaseIterable {
    case proMonthly = "com.balliqfantasy.app.pro.monthly"
    case proYearly = "com.balliqfantasy.app.pro.yearly"
    case draftSpinPack = "com.balliqfantasy.app.pack.draftspin"
    case gridPack = "com.balliqfantasy.app.pack.grid"

    var isSubscription: Bool { self == .proMonthly || self == .proYearly }

    /// What a one-time pack actually unlocks, in the user's terms. Lives here rather than in
    /// the App Store Connect description so the paywall can say it per-row — a bare product
    /// name and a price is not enough to tell two packs apart.
    var packBlurb: LocalizedStringResource? {
        switch self {
        case .draftSpinPack:
            return "Casino-style draft mode: spin, draft, and beat the board."
        case .gridPack:
            return "The 3×3 immortality grid, every day."
        case .proMonthly, .proYearly:
            return nil
        }
    }
}
