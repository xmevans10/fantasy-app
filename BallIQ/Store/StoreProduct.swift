import Foundation

/// The app's StoreKit product catalog — IDs must match `Products.storekit` (simulator
/// testing) and the live App Store Connect records (hand-off, see BALLIQ_SPEC.md M5).
enum StoreProduct: String, CaseIterable {
    case proMonthly = "com.balliqfantasy.app.pro.monthly"
    case proYearly = "com.balliqfantasy.app.pro.yearly"
    case draftSpinPack = "com.balliqfantasy.app.pack.draftspin"
    case gridPack = "com.balliqfantasy.app.pack.grid"

    var isSubscription: Bool { self == .proMonthly || self == .proYearly }
}
