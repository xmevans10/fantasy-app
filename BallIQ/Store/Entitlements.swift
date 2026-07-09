import Foundation

/// Single source of truth the UI reads for what the current user can access. Derived from
/// StoreKit's own verified transaction store (`StoreService.refreshEntitlements`) — never
/// granted from an unverified client-side claim alone.
struct Entitlements: Equatable {
    var isPro: Bool = false
    var unlockedPacks: Set<String> = []
    /// Admin flag overrides every gate — moderation, paywalled features, all sports.
    var isAdmin: Bool = false

    static let free = Entitlements()

    /// Sports playable on the daily filter without Pro. `.all` (no specific sport) is
    /// always selectable — it just narrows what it *shows* to the free sports too.
    static let freeSports: Set<Sport> = [.nfl, .nba]

    func canSelect(_ filter: SportFilter) -> Bool {
        guard let sport = filter.sport else { return true }
        return isPro || isAdmin || Self.freeSports.contains(sport)
    }

    var canPlayHardMode: Bool { isPro || isAdmin }
    var canAccessArchive: Bool { isPro || isAdmin }
    var hasUnlimitedOverUnderLives: Bool { isPro || isAdmin }

    func canPlayGrid() -> Bool { isPro || isAdmin || unlockedPacks.contains(StoreProduct.gridPack.rawValue) }
    func canPlayDraftSpin() -> Bool { isPro || isAdmin || unlockedPacks.contains(StoreProduct.draftSpinPack.rawValue) }
}
